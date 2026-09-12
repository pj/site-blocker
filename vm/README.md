# SiteBlocker VM end-to-end tests

End-to-end testing for the SiteBlocker **macOS** app on a [Tart](https://tart.run/) VM (`macos-dev`),
modelled on the harness in the `window_thing` repo.

It drives the *real* app through its whole pipeline — load `lists.json` → `ListEngine` → `Enforcer`
→ write `PolicySnapshot` — and asserts on the snapshot the content-filter system extension reads
(`/Users/Shared/SiteBlocker/policy.json`). No UI automation, so no Accessibility approval is needed.

## Prerequisites

```bash
brew install cirruslabs/cli/tart
brew install hudochenkov/sshpass/sshpass
```

A built `macos-dev` VM (shared with other projects). The host needs the usual SiteBlocker build
toolchain (`just build` must work).

## Run

```bash
just e2e                 # build, boot the VM, run every scenario, stop the VM
just e2e --keep          # leave the VM running afterwards
just e2e --filter 02     # only scenarios whose file name contains "02"
just e2e --skip-unit     # skip the host-side RulesEngine unit tests
# equivalently: ./vm/run-e2e.sh [args]
```

`run-e2e.sh`:
1. Builds `SiteBlocker.app` (Debug) and the `sb-driver` helper **on the host** (the VM has no Swift
   toolchain).
2. Runs the `RulesEngine` unit tests on the host (unless `--skip-unit`).
3. Boots the VM headlessly, rsyncs `vm/` + copies the two artifacts into `~/Projects/site_blocker`.
4. Runs `vm/scripts/e2e-test.sh` **inside the VM's GUI session** (via `launchctl asuser 501`), which
   drives the scenarios and asserts on the snapshot.

## How it works

Nothing is built in the VM — the app bundle and `sb-driver` are compiled on the host and copied in
(same arch, so they run unchanged). `sb-driver` is compiled straight from the `RulesEngine` sources,
so the `lists.json` it writes is guaranteed to decode in the app and its snapshot check uses the
engine's own membership logic.

Each scenario: quit the app → write a fixture `lists.json` → clear usage + snapshot → launch the app
→ wait for a fresh snapshot → assert blocked/allowed per host. See `vm/scripts/e2e-lib.sh`.

```
vm/
├── run-e2e.sh                 host orchestrator (build, sync, drive the VM)
├── README.md
└── scripts/
    ├── sb-driver.swift        fixtures + snapshot assertions (compiled with RulesEngine on the host)
    ├── e2e-lib.sh             app lifecycle + assertions (runs in the VM)
    ├── e2e-test.sh            in-VM runner: sources the scenarios
    └── e2e-tests/
        ├── 01-smoke.sh          app launches and resolves a snapshot
        ├── 02-content-filter.sh a listed domain (+ subdomains) is blocked; unlisted allowed; flip to allowed
        ├── 03-persistence.sh    a list survives a relaunch; snapshot rebuilt from disk
        └── 04-exceptions.sh     schedule / always / location exceptions flip the blocked state
```

## What this does and does not prove

**Proves** (end to end, real app, on real macOS): the app loads its lists, resolves the correct
blocked set through `ListEngine`, and writes the `PolicySnapshot` the extension consumes; base state
and exceptions (always-allow, in-window vs out-of-window schedules, signal-gated location) flip that
set correctly; and the set survives a relaunch from `lists.json`. The snapshot *is* the filter's
entire input — the extension blocks a flow iff the SNI host matches a blocked pattern by the same
suffix rule `sb-driver` applies — so a snapshot verdict is the allow/deny the installed filter would
return for that hostname.

**Does not prove** a live packet drop. Installing the `NEFilterDataProvider` system extension needs
sysext approval, and `macos-dev` has **SIP enabled**, so it can neither enable
`systemextensionsctl developer` mode (needs SIP off) nor surface the notarized-app approval flow
headlessly. Closing that gap needs one of:
- a notarized Release build (`just package`) installed in the VM, approved once on the VM's screen
  under *System Settings → Login Items & Extensions*, then a real-network allow/deny check (e.g.
  `curl https://example.com` with the domain blocked); or
- a VM image built with SIP disabled + `systemextensionsctl developer on`.

**Not yet covered** (future slices): the *active-signal* side of calendar and location exceptions —
the inactive side is asserted (a signal-gated exception stays shut with no signal), but seeding a
live calendar event or a location fix in the headless VM to assert the *open* side is future work.
