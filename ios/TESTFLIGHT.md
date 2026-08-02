# SiteBlocker for iPhone — permanent install via TestFlight

iOS has no Developer ID / Sparkle equivalent: you can't sideload a self-updating app. TestFlight is
the way to keep SiteBlocker installed on your iPhone and update it with **one tap, over the air**.

This build blocks **websites in Safari** via a Content Blocker extension. It uses **no Family
Controls / Screen Time entitlement**, so there's no special Apple approval to wait on — it goes
straight to TestFlight. (App blocking and time-of-day scheduling would need the Family Controls
distribution entitlement; see the git history for that path if you revisit it.)

Once set up, the whole update loop is:

```
just ios-release        # build → upload; then tap "Update" in the TestFlight app on your phone
```

Two ongoing caveats:
- **Builds expire 90 days after upload.** Re-run `just ios-release` within 90 days to keep it alive
  (the app keeps working until then; a fresh upload resets the clock).
- Bump `MARKETING_VERSION` in `ios/project.yml` when you want a new *user-facing* version number.
  The build number is set to a timestamp automatically, so every upload is unique without a bump.

---

## One-time setup

### 1. App Store Connect app record

Create the app at <https://appstoreconnect.apple.com> → **Apps → +**:
- Platform: iOS, Name: SiteBlocker (names must be globally unique — add a suffix if taken),
  Primary language, Bundle ID: **com.pauljohnson.siteblocker.ios**, an SKU (any string).

The Content Blocker extension (`…ios.ContentBlocker`) ships *inside* the app — it doesn't get its own
App Store Connect record, and its App ID is registered automatically by `-allowProvisioningUpdates`
during archive. Both App IDs just need the **App Groups** capability (automatic signing handles it).

### 2. App Store Connect API key (for command-line upload)

App Store Connect → **Users and Access → Integrations → App Store Connect API → Generate API Key**
(role **App Manager**). Then:
- Download `AuthKey_<KEY_ID>.p8` (you can only download it once) and move it to
  `~/.appstoreconnect/private_keys/`.
- Copy `ASC_KEY_ID` (the Key ID) and `ASC_ISSUER_ID` (the Issuer ID above the key list) into `.env`.

### 3. First upload + install on your phone

```
just ios-release
```

After Apple finishes processing (~5–15 min), in App Store Connect → your app → **TestFlight**:
- Add yourself under **Internal Testing** (internal testers need no Beta App Review).
- Install the **TestFlight** app from the App Store on your iPhone, sign in with the same Apple ID,
  and install SiteBlocker from it.
- Open SiteBlocker, add your blocked sites, and **enable the content blocker** in
  **iOS Settings → Safari → Extensions** (or Settings → Apps → Safari → Extensions) if prompted.

---

## Updating (the easy part)

```
just ios-release        # optionally bump MARKETING_VERSION in ios/project.yml first
```

The new build shows up in the TestFlight app on your phone — tap **Update**. No cable, no Xcode.

## Troubleshooting

- **`ios-archive` fails with a provisioning error** → an App ID is missing the **App Groups**
  capability, or the bundle IDs don't match what's registered. Automatic signing usually fixes this
  on the next run; check the Apple Developer portal → Identifiers.
- **`altool` can't find the key** → the file must be named exactly `AuthKey_<ASC_KEY_ID>.p8` and live
  in `~/.appstoreconnect/private_keys/`.
- **Build never appears in TestFlight** → check the processing/rejection email from App Store Connect;
  export-compliance is pre-answered via `ITSAppUsesNonExemptEncryption=false` in the app Info.plist.
- **Sites aren't blocked** → make sure the SiteBlocker extension is enabled in Safari's extensions
  settings and that "Blocking on" is set in the app.
