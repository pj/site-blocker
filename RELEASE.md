# Releasing SiteBlocker

SiteBlocker ships as a **Developer ID–signed, notarized, stapled** `.app` — it runs on any
macOS 15+ Mac with no dev account, no profiles, and no Gatekeeper warning. The only complicated
part is the one-time signing setup on the *build* machine; everything below documents it.

## TL;DR

```sh
just package          # → SiteBlocker-dist.zip  (signed, notarized, stapled)
```

Copy that zip to any Mac, unzip, drag `SiteBlocker.app` to `/Applications`, launch. Done.
(`just install` does the same but installs to *this* machine's `/Applications` and launches it.)

---

## Why this app needs provisioning profiles at all

Most Developer ID Mac apps need **no** provisioning profile. SiteBlocker does, because it uses
**restricted entitlements** that a profile must authorize *at signing time*:

| Entitlement | Why | Authorized by App-ID capability |
|---|---|---|
| `com.apple.developer.networking.networkextension` = `content-filter-provider-systemextension` | the content filter | **Network Extensions** |
| `com.apple.developer.system-extension.install` | app installs its own system extension | **System Extension** |
| `com.apple.security.application-groups` | app↔extension shared group id | **App Groups** |
| `com.apple.developer.ubiquity-kvstore-identifier` | iCloud rules/usage sync | **iCloud → "Compatible with Xcode 5"** |

The profile is **embedded into the app bundle** at build time (`Contents/embedded.provisionprofile`,
and one in the extension too). At runtime macOS validates the app's entitlements against that
embedded copy. **Because it travels inside the signed app, target machines never install profiles.**
Profiles are purely a build/signing concern.

> Developer ID profiles specifically — Apple's *development* profiles only carry
> `content-filter-provider` (no `-systemextension` variant), so a system extension can never ship
> through a dev-signed build. And they must be **manually created** in the portal; Xcode-managed
> "Direct" profiles are rejected by CLI manual signing.

---

## One-time build-machine setup

Everything here is already in place on the current build Mac (profiles valid until **2044**). You
only redo this on a brand-new build machine, or when changing a capability (see "Changing
capabilities").

### 1. Signing certificate
Install the **Developer ID Application** certificate + private key into the login keychain
(export from the existing machine as a `.p12`, or re-download from the portal with the key).
Verify: `security find-identity -v -p codesigning` shows
`Developer ID Application: Paul Johnson (YF7LH93MG3)`.

### 2. App IDs + capabilities (developer.apple.com → Identifiers)
Two App IDs, each with exactly these capabilities enabled:

- **`com.pauljohnson.siteblocker.app`** — Network Extensions, System Extension, App Groups,
  iCloud (choose **Compatible with Xcode 5**, *not* CloudKit).
- **`com.pauljohnson.siteblocker.app.FilterExtension`** — Network Extensions, App Groups.

App Group `group.com.pauljohnson.siteblocker` must exist and be assigned to both.

### 3. Provisioning profiles (developer.apple.com → Profiles)
Create **two Developer ID** profiles (type: Developer ID, not Development/App Store), one per App
ID, download both, and install them:

```sh
cp ~/Downloads/SiteBlocker_App_Developer_ID*.provisionprofile        ~/Library/MobileDevice/Provisioning\ Profiles/
cp ~/Downloads/SiteBlocker_Extension_Developer_ID*.provisionprofile  ~/Library/MobileDevice/Provisioning\ Profiles/
```

Their **names** (not filenames) are what the build references — confirm with:
```sh
security cms -D -i <profile> | plutil -extract Name raw -
# expected: "SiteBlocker App Developer ID"  /  "SiteBlocker Extension Developer ID"
```

### 4. Notarization credentials
```sh
xcrun notarytool store-credentials siteblocker \
  --apple-id <your-apple-id> --team-id YF7LH93MG3 --password <app-specific-password>
```
`siteblocker` is the keychain-profile name the justfile expects (override with `NOTARY_PROFILE`).
Generate the app-specific password at <https://account.apple.com> → Sign-In & Security.

### 5. `.env` (gitignored)
```
DEVELOPMENT_TEAM=YF7LH93MG3
APP_PROVISIONING_PROFILE="SiteBlocker App Developer ID"
EXT_PROVISIONING_PROFILE="SiteBlocker Extension Developer ID"
```
(Values with spaces **must** be quoted — just's dotenv parser requires it.)

### 6. Toolchain
The nix flake dev shell provides `just`, `xcodegen`, etc.; Xcode (full, for `xcodebuild` +
`notarytool` + `stapler`) must be installed and selected (`xcode-select`).

---

## How signing is wired (mac/project.yml)

Both targets use **manual** signing:
- `CODE_SIGN_STYLE: Manual`, `CODE_SIGN_IDENTITY: Developer ID Application`
- `PROVISIONING_PROFILE_SPECIFIER: ${APP_PROVISIONING_PROFILE}` / `${EXT_PROVISIONING_PROFILE}`
- `ENABLE_HARDENED_RUNTIME: YES` (required for notarization)

`just package`/`just install` build with:
- `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` — drops the debug `get-task-allow` entitlement that
  fails notarization.
- `OTHER_CODE_SIGN_FLAGS=--timestamp` — secure timestamp, also required by notarization.

Then: `ditto` zip → `notarytool submit --wait` → **`stapler staple` the app only** (never the
nested extension — stapling it modifies the bundle after the app sealed it and breaks the app's
`--deep` signature; notarization already covers the extension by cdhash) → re-zip the stapled app.

Entitlements files (not profile-gated, so freely set — no capability needed):
- App is **not** sandboxed; it has `com.apple.security.automation.apple-events` (close browser
  tabs) — a hardened-runtime entitlement, no profile authorization needed.
- Extension **is** sandboxed and has
  `com.apple.security.temporary-exception.files.absolute-path.read-only = [/Users/Shared/SiteBlocker/]`
  so the (root, sandboxed) extension can read the snapshot the app writes.

---

## Updating an already-installed copy

When you ship a new build to a machine that already has SiteBlocker, **bump the version** or the OS
keeps running the *old* system extension:

- Edit `mac/project.yml`: `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `settings.base`
  **and** `CFBundleShortVersionString` / `CFBundleVersion` in **both** targets' `info.properties`
  (XcodeGen does not wire the former into the plist, so set both).
- Same version = the OS treats the extension as unchanged and won't swap the binary.

---

## Installing on a target Mac (no profiles, no account)

1. Unzip, move `SiteBlocker.app` to `/Applications`, launch.
2. **Approve the system extension**: System Settings → General → Login Items & Extensions →
   **Network Extensions** → enable SiteBlocker. (Nothing is filtered until you do.)
3. Grant **Automation** permission when it first closes a browser tab (per browser).
4. Allow **Notifications** (budget countdown).
5. iCloud is **optional** — with the same iCloud account, rules + usage sync in; without it, the app
   runs fully standalone on local storage.

Verify a build is distributable:
```sh
spctl -a -vvv SiteBlocker.app     # → accepted, source=Notarized Developer ID
xcrun stapler validate SiteBlocker.app
```

---

## Auto-update

SiteBlocker checks GitHub Releases for updates via [Sparkle](https://sparkle-project.org)
(`mac/project.yml` pulls it in as an SPM package). The app has a "Check for Updates…" menu item
and also checks automatically once a day (`SUScheduledCheckInterval` in `mac/project.yml`);
`SUAllowsAutomaticUpdates` is `false`, so installs still require the user to click through
Sparkle's standard "Install Update" prompt rather than happening silently in the background.

**How it's wired:**
- `SUFeedURL` (in `mac/project.yml`, target `SiteBlocker` → `info.properties`) points at
  `appcast.xml` at the repo root, served unauthenticated via `raw.githubusercontent.com` (the repo
  is public — a private repo would need a different hosting/auth story).
- `SUPublicEDKey` is the EdDSA public half of a signing keypair. The private half lives **only** in
  this build machine's login keychain (`sparkle-tools/bin/generate_keys` created it once — same
  one-time-per-machine pattern as the notarization credentials above). Anyone can read the appcast
  and the release zips, but only this machine can produce an update Sparkle will accept — Sparkle
  refuses any enclosure whose signature doesn't verify against `SUPublicEDKey`.

**Publishing a release:**
```sh
just release
```
This is a separate, explicit step from `just package` — run it once you're ready to publish, after
bumping and committing the version (see "Updating an already-installed copy" above). It:
1. Runs `just package` (builds, notarizes, staples → `SiteBlocker-dist.zip`).
2. Downloads Sparkle's CLI tools into `build/sparkle-tools` (cached after the first run).
3. Pushes the current commit, then signs the zip (`sign_update`) with the keychain private key.
4. Creates a GitHub Release (`vX.Y`) on that commit and uploads the zip as an asset.
5. Appends an `<item>` to `appcast.xml` (`scripts/append_appcast_item.py`) with the new version,
   download URL, and signature, then commits and pushes it.

Refuses to run if the working tree isn't clean or the release tag already exists. Requires `gh` to
be authenticated with push access to the repo.

If a machine other than this one ever needs to publish releases, it needs its own Developer ID
cert + notarization credentials (see above) **and** the Sparkle private key exported from this
machine's keychain (`generate_keys -x <path>` to export, `generate_keys -f <path>` to import) —
don't generate a second keypair, or `SUPublicEDKey` in already-shipped builds won't match.

---

## Changing capabilities (the only time profiles come back)

If you add an entitlement that's profile-gated (a new `com.apple.developer.*` or App Group /
iCloud / extension capability), you must: enable the capability on the App ID → regenerate that
Developer ID profile → reinstall it → add the entitlement to the `.entitlements` file. Signing fails
with *"provisioning profile doesn't include the … entitlement"* until the profile is updated. This
has happened for: Network Extensions, System Extension, App Groups, and iCloud KVS.

---

## Gotchas (learned the hard way)

- **`xcodegen`** from nixpkgs must be invoked via its resolved real path (`readlink -f`) or it
  can't find SettingPresets → empty `PRODUCT_NAME` → `module name "" is not a valid identifier`.
  The `generate` recipe already does this.
- The extension's **`PRODUCT_NAME` must equal its bundle identifier** (macOS 26/Tahoe), with
  `PRODUCT_MODULE_NAME: FilterExtension` pinned so `NEProviderClasses` stays valid — else activation
  fails "Extension not found in App bundle".
- **`NSSystemExtensionUsageDescription`** must be in the **extension's** Info.plist too (Tahoe), not
  just the app's.
- The container app must be **non-sandboxed** (Developer ID) to talk to `sysextd`; only the
  extension is sandboxed.
- Notarization needs hardened runtime + secure timestamp + no `get-task-allow` (all handled by the
  build flags above).
