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
