# site_blocker

A rules-based content/website blocker for macOS. Rules can block on time of day, day of week,
date range, and how much "unblocked" (distraction) time you've already spent today — composed
with AND / OR / NOT.

## Status

- ✅ **`RulesEngine`** — the rules model + evaluation. Pure Swift, no platform deps, unit-tested.
- ✅ **Mac app (SwiftUI)** — rules list, status ("what's blocked now"), a preview panel
  ("what would be blocked at 3pm Tuesday"), and a debug control to simulate usage.
- ✅ **Real enforcement** via a `NEFilterDataProvider` content-filter system extension (default
  build). `MockEnforcer` remains as a no-account fallback behind the `ENABLE_NETWORK_EXTENSION`
  flag. See "Signing / credentials".

## Architecture

```
RulesEngine/                Pure Swift package — the brain. Shared by app + extension.
  Condition / Rule          Composable conditions (time/date/weekday/usage-quota + and/or/not)
  BlockEngine               Evaluate rules → blocked host set / per-flow decision
  DailyUsage                Per-local-day "unblocked time" accounting
  PolicySnapshot            Serializable app→extension hand-off (rules + usage)
  Enforcer / MockEnforcer   Enforcement abstraction + in-memory stand-in

mac/
  App/                      SwiftUI app: rules UI + coordinator (RuleStore) + persistence
    SystemExtensionEnforcer   Real NEFilterManager/OSSystemExtension path (mocked out)
  FilterExtension/          NEFilterDataProvider content filter — decides live flows using
                            the shared BlockEngine + PolicySnapshot
```

**Data flow:** `RuleStore` owns rules + usage, recomputes on a timer, and writes a
`PolicySnapshot` into the shared App Group container. The content-filter extension re-reads that
snapshot and evaluates each network flow with the *same* `BlockEngine` the app uses — so all the
interesting logic stays in one unit-tested place.

## Why not the hosts file / DNS?

Browsers now use DNS-over-HTTPS and iCloud Private Relay, which tunnel past `/etc/hosts` and
local DNS. A `NEFilterDataProvider` content filter sees the actual flows (with source app + host),
so it isn't bypassed the same way. See `docs` / commit history for the options considered
(local proxy and `pf` were the account-free alternatives).

## Develop

```sh
nix develop                 # tooling (just, xcodegen, swiftformat, xcbeautify, jj)
cp .env.example .env        # then set DEVELOPMENT_TEAM (see "Signing" below)
just                        # list recipes
just test                   # run the engine tests
just build                  # Debug build (compile check; dev-signed)
just install                # notarized Developer ID build → /Applications (loads the filter)
```

Common recipes: `just generate | build | run | install | test | format | signing-info |
sysext-status | clean`. `build` is an unsigned compile check; `install` is the signed+notarized path.

## Signing / credentials

Running a **content-filter system extension with SIP on** requires a Developer ID signed + notarized
build. The hard-won gotchas (see commit history — this took a while):

- The entitlement has two variants. Apple's **development** provisioning profiles only ever carry
  `content-filter-provider`; only **Developer ID** profiles carry `content-filter-provider-systemextension`,
  which is the one a system extension actually needs. So anything routed through a dev-signed archive
  (CLI `-exportArchive` **or** Xcode's Organizer) dead-ends on an entitlement mismatch.
- The fix: **build straight against a manually-created Developer ID provisioning profile** (manual
  signing, no development step). Xcode's *managed* Developer ID profiles can't be used from the CLI,
  so the profiles must be created by hand in the portal.

One-time setup:

1. **Developer ID Application certificate** — create in Xcode → Settings → Accounts → Manage
   Certificates if you don't have one.
2. **Two Developer ID provisioning profiles** at developer.apple.com → Profiles → **Developer ID**,
   one per App ID (`com.pauljohnson.siteblocker.app` and `…app.FilterExtension`), each tied to the
   Developer ID Application cert. Download and double-click to install. Put their names in `.env`
   as `APP_PROVISIONING_PROFILE` / `EXT_PROVISIONING_PROFILE` (quote values with spaces).
3. **Team ID + notarization creds** in `.env`:
   ```
   DEVELOPMENT_TEAM=XXXXXXXXXX
   ```
   ```sh
   xcrun notarytool store-credentials siteblocker --apple-id you@example.com --team-id XXXXXXXXXX
   ```
   (app-specific password from appleid.apple.com; override the profile name with `NOTARY_PROFILE`).

The signing itself (manual Developer ID, hardened runtime, `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`
to drop `get-task-allow`, `--timestamp` for the secure timestamp) is handled by `mac/project.yml`
and the `install` recipe. Bundle IDs are `com.pauljohnson.siteblocker.*`; to change the prefix, edit
`mac/project.yml`, the App Group id in both entitlements files, `PersistenceController.appGroupID`,
and `FilterDataProvider.appGroupID`.

Then: `just install` → approve the extension in System Settings → `just sysext-status` to confirm.

Build against the mock instead (no account needed) by removing the
`SWIFT_ACTIVE_COMPILATION_CONDITIONS: ENABLE_NETWORK_EXTENSION` line from `mac/project.yml`.
