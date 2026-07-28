# site_blocker task runner — run `just` to list recipes.
# Code-signing config is read from a gitignored .env (copy .env.example). The DEVELOPMENT_TEAM
# value is exported into the recipe environment and picked up by `xcodegen generate`.

set dotenv-load := true

spec    := "mac/project.yml"
project := "mac/SiteBlocker.xcodeproj"
scheme  := "SiteBlocker"
config  := "Debug"
ddata   := "build"
appdir  := ddata / "Build/Products" / config / "SiteBlocker.app"
# Keychain profile holding notarization credentials (see `install`). Override in .env.
notary_profile := env_var_or_default("NOTARY_PROFILE", "siteblocker")

# GitHub repo releases are published to, and the Sparkle CLI tools (sign_update, etc.) used to
# sign each update — see RELEASE.md "Auto-update".
gh_repo         := "pj/site-blocker"
sparkle_version := "2.9.4"
sparkle_tools   := ddata / "sparkle-tools"

# List available recipes
default:
    @just --list

# Invoke xcodegen by its *resolved* path: the nixpkgs binary locates its bundled SettingPresets
# relative to its own executable, which breaks when run via the /etc/profiles symlink (presets
# aren't found → empty PRODUCT_NAME → `module name "" is not a valid identifier` at build time).
# Regenerate SiteBlocker.xcodeproj from the spec (uses $DEVELOPMENT_TEAM).
generate:
    xcg="$(readlink -f "$(command -v xcodegen)")"; "$xcg" generate --spec {{spec}}

# Generate the iOS Xcode project (Screen Time app, shares RulesEngine)
ios-generate:
    xcg="$(readlink -f "$(command -v xcodegen)")"; "$xcg" generate --spec ios/project.yml

# Compile-check the iOS app for the simulator (no signing needed)
ios-build: ios-generate
    xcodebuild -project ios/SiteBlockerMobile.xcodeproj -scheme SiteBlockerMobile \
        -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
        CODE_SIGNING_ALLOWED=NO build | xcbeautify

# Run the RulesEngine unit tests — where the logic is verified
test:
    cd RulesEngine && swift test

# Signing/notarization happens in `install`; the -systemextension entitlement can't be satisfied
# by Debug development signing, so we skip signing here.
# Compile check the app + extension (Debug, unsigned).
build: generate
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration {{config}} \
        -destination 'platform=macOS' -derivedDataPath {{ddata}} \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build | xcbeautify

# Build then launch the app
run: build
    open {{appdir}}

# Format Swift sources
format:
    swiftformat .

# SIP-ON path: build a Developer ID signed Release (manual signing with the Developer ID profiles
# from .env), notarize, staple, install to /Applications. A notarized system extension activates
# with only the System Settings approval — no `systemextensionsctl developer` / SIP disabling.
# One-time cred setup (app-specific password from appleid.apple.com):
#   xcrun notarytool store-credentials {{notary_profile}} --apple-id you@example.com --team-id "$DEVELOPMENT_TEAM"
install: generate
    #!/usr/bin/env bash
    set -euo pipefail
    app="{{ddata}}/Build/Products/Release/SiteBlocker.app"
    # Release build is Developer ID signed with hardened runtime + entitlements baked in
    # (manual signing per mac/project.yml). No archive/export dance needed.
    # CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO drops the debug get-task-allow entitlement, and
    # --timestamp adds the secure timestamp — both required to pass notarization.
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Release \
        -derivedDataPath {{ddata}} \
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp \
        build | xcbeautify

    ditto -c -k --keepParent "$app" "{{ddata}}/SiteBlocker.zip"
    xcrun notarytool submit "{{ddata}}/SiteBlocker.zip" --keychain-profile "{{notary_profile}}" --wait
    # Staple the app only. Notarization covers the nested system extension by cdhash; stapling the
    # nested bundle would modify it after the app sealed it and break the app's --deep signature.
    xcrun stapler staple "$app"

    rm -rf /Applications/SiteBlocker.app
    cp -R "$app" /Applications/SiteBlocker.app
    open /Applications/SiteBlocker.app

# Build a distributable, notarized + stapled zip to copy to another Mac (does not touch /Applications)
package: generate
    #!/usr/bin/env bash
    set -euo pipefail
    app="{{ddata}}/Build/Products/Release/SiteBlocker.app"
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Release \
        -derivedDataPath {{ddata}} \
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp \
        build | xcbeautify

    ditto -c -k --keepParent "$app" "{{ddata}}/SiteBlocker.zip"
    xcrun notarytool submit "{{ddata}}/SiteBlocker.zip" --keychain-profile "{{notary_profile}}" --wait
    xcrun stapler staple "$app"                    # ticket now travels inside the .app (works offline)
    xcrun stapler validate "$app"

    # Re-zip the *stapled* app for distribution (the notarize zip above predates the staple).
    rm -f SiteBlocker-dist.zip
    ditto -c -k --keepParent "$app" SiteBlocker-dist.zip
    echo "→ SiteBlocker-dist.zip — copy to the other Mac, unzip, drag to /Applications"

# Re-zip the already-installed /Applications app (notarized+stapled by `install`) for copying to
# another Mac — no re-notarization. This is the file to distribute: SiteBlocker-dist.zip.
dist:
    xcrun stapler validate /Applications/SiteBlocker.app
    ditto -c -k --keepParent /Applications/SiteBlocker.app SiteBlocker-dist.zip
    @echo "→ SiteBlocker-dist.zip — copy this to the other Mac"

# Download Sparkle's CLI tools (sign_update, generate_appcast) into build/, cached across runs.
sparkle-tools:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -x "{{sparkle_tools}}/bin/sign_update" ]; then
        echo "→ fetching Sparkle {{sparkle_version}} CLI tools"
        rm -rf "{{sparkle_tools}}"
        mkdir -p "{{sparkle_tools}}"
        tmp="$(mktemp).tar.xz"
        curl -sL -o "$tmp" \
            "https://github.com/sparkle-project/Sparkle/releases/download/{{sparkle_version}}/Sparkle-{{sparkle_version}}.tar.xz"
        tar -xf "$tmp" -C "{{sparkle_tools}}" bin
        xattr -dr com.apple.quarantine "{{sparkle_tools}}/bin" 2>/dev/null || true
        rm -f "$tmp"
    fi

# Publish a new release: package (signed, notarized, stapled), sign the update for Sparkle,
# upload to a GitHub Release, and record it in appcast.xml. Run this *after* bumping
# MARKETING_VERSION/CURRENT_PROJECT_VERSION in mac/project.yml (see RELEASE.md "Updating an
# already-installed copy") and committing that bump — this recipe reads the versions back out of
# the built app rather than taking them as arguments, so the two can't drift.
# Requires: gh authenticated (`gh auth login`), the EdDSA private key in this machine's login
# keychain (`sparkle-tools/bin/generate_keys`, one-time), a clean working tree.
release: package sparkle-tools
    #!/usr/bin/env bash
    set -euo pipefail
    app="{{ddata}}/Build/Products/Release/SiteBlocker.app"
    short_version="$(defaults read "$(pwd)/$app/Contents/Info" CFBundleShortVersionString)"
    build="$(defaults read "$(pwd)/$app/Contents/Info" CFBundleVersion)"
    tag="v${short_version}"
    zip="SiteBlocker-dist.zip"

    if [ -n "$(git status --porcelain)" ]; then
        echo "error: working tree not clean — commit the version bump first" >&2
        exit 1
    fi
    if gh release view "$tag" --repo "{{gh_repo}}" >/dev/null 2>&1; then
        echo "error: release $tag already exists" >&2
        exit 1
    fi

    # Push first so the tag `gh release create` makes on GitHub points at this exact commit
    # (not whatever the remote default branch happened to be at).
    git push
    commit="$(git rev-parse HEAD)"

    sig_line="$("{{sparkle_tools}}/bin/sign_update" "$zip")"
    # sig_line looks like: sparkle:edSignature="..." length="..."
    signature="$(echo "$sig_line" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')"
    length="$(echo "$sig_line" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"

    gh release create "$tag" "$zip" \
        --repo "{{gh_repo}}" --title "$tag" --target "$commit" \
        --notes "SiteBlocker $short_version"
    # gh's `assets[].url` is already the public browser_download_url (not the API url).
    url="$(gh release view "$tag" --repo "{{gh_repo}}" --json assets \
        --jq '.assets[] | select(.name == "SiteBlocker-dist.zip") | .url')"

    python3 scripts/append_appcast_item.py --appcast appcast.xml \
        --version "$build" --short-version "$short_version" \
        --url "$url" --length "$length" --signature "$signature"

    git add appcast.xml
    git commit -m "Release $tag"
    git push
    echo "→ $tag published, appcast.xml updated and pushed"

# Print resolved signing settings — handy when provisioning misbehaves
signing-info: generate
    xcodebuild -project {{project}} -scheme {{scheme}} -showBuildSettings \
        | grep -E 'DEVELOPMENT_TEAM|CODE_SIGN|PRODUCT_BUNDLE_IDENTIFIER|PROVISIONING'

# Stream the app's live logs (target-source reads/fetches and their errors)
logs:
    /usr/bin/log stream --level info --predicate 'subsystem == "com.pauljohnson.siteblocker"'

# Show the app's logs from the last hour
logs-recent:
    /usr/bin/log show --last 1h --info --predicate 'subsystem == "com.pauljohnson.siteblocker"'

# Show SiteBlocker's system-extension activation status
sysext-status:
    systemextensionsctl list | grep -i siteblocker || systemextensionsctl list

# Remove the generated project + build artifacts
clean:
    rm -rf {{project}} {{ddata}} RulesEngine/.build
