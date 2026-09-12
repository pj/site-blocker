#!/usr/bin/env bash
# e2e-lib.sh — shared machinery for the SiteBlocker end-to-end tests.
#
# Sourced by each file in vm/scripts/e2e-tests/, which run *inside* the VM in the logged-in GUI
# session. The app is a menu-bar agent that needs an Aqua session to run and a WindowServer to draw
# into, so these cannot run over a bare SSH session — vm/run-e2e.sh launches the runner through
# `launchctl asuser`.
#
# How a scenario is driven, and why it needs no Accessibility:
#   1. write a fixture lists.json (via the compiled sb-driver) into Application Support,
#   2. launch SiteBlocker.app,
#   3. read back the PolicySnapshot the app resolves to /Users/Shared/SiteBlocker/policy.json —
#      the exact file the content-filter extension reads — and assert on it.
# The whole app pipeline runs (load → ListEngine → Enforcer → snapshot), but nothing clicks the UI,
# so there is no TCC Accessibility approval to arrange on a SIP-on image.

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
APP="$PROJECT_DIR/build/SiteBlocker.app"
SB="$PROJECT_DIR/build/sb-driver"

# Built on the host and copied in — the VM has no Swift toolchain.
LISTS="$HOME/Library/Application Support/SiteBlocker/lists.json"
SUPPORT_DIR="$HOME/Library/Application Support/SiteBlocker"
SNAPSHOT="/Users/Shared/SiteBlocker/policy.json"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; DIM='\033[2m'; NC='\033[0m'

: "${PASS_COUNT:=0}"
: "${FAIL_COUNT:=0}"

pass() { echo -e "  ${GREEN}pass${NC}  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}  $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
info() { echo -e "${YELLOW}==>${NC} $1"; }
note() { echo -e "     ${DIM}$1${NC}"; }

# --------------------------------------------------------------------------- #
# App lifecycle                                                                 #
# --------------------------------------------------------------------------- #

quit_app() {
    pkill -x SiteBlocker 2>/dev/null || true
    for _ in $(seq 1 20); do
        pgrep -x SiteBlocker >/dev/null || break
        sleep 0.3
    done
}

# Launch via `open`, so LaunchServices registers the bundle id and the app comes up as its own
# responsible process. Retried because, for a moment after it quits, LaunchServices still thinks it
# is running and refuses with -600.
open_app() {
    local attempt
    for attempt in 1 2 3; do
        if open -a "$APP" 2>/tmp/sb-open.log; then return 0; fi
        note "open refused the app (attempt $attempt): $(tr -d '\n' </tmp/sb-open.log)"
        sleep 1
    done
    return 1
}

# Wait for the app to write a fresh snapshot. The snapshot is deleted before launch, so its mere
# existence means this run produced it; age is a second belt-and-braces check.
wait_for_snapshot() {
    local deadline=$((SECONDS + 30))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ -f "$SNAPSHOT" ]; then
            local age; age="$("$SB" age "$SNAPSHOT" 2>/dev/null || echo 999)"
            if [ "$age" -ge 0 ] 2>/dev/null && [ "$age" -le 120 ]; then return 0; fi
        fi
        sleep 0.3
    done
    return 1
}

# Quit, install a scenario's fixture, clear prior usage + snapshot, relaunch, and wait for the app
# to resolve a fresh snapshot.
launch_scenario() {
    local scenario="$1"
    quit_app
    mkdir -p "$SUPPORT_DIR"
    rm -f "$SUPPORT_DIR/usage.json"          # reset today's budget so limits are deterministic
    "$SB" write-lists "$scenario" "$LISTS" >/dev/null || { fail "could not write fixture '$scenario'"; return 1; }
    sudo rm -f "$SNAPSHOT" 2>/dev/null || rm -f "$SNAPSHOT" 2>/dev/null || true
    xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
    if ! open_app; then fail "the app could not be launched"; return 1; fi
    if ! pgrep -x SiteBlocker >/dev/null 2>&1; then
        sleep 1
        pgrep -x SiteBlocker >/dev/null 2>&1 || { fail "the app is not running after launch"; dump_app_log; return 1; }
    fi
    if ! wait_for_snapshot; then
        fail "no fresh snapshot was written within 30s (scenario '$scenario')"
        dump_app_log
        return 1
    fi
    return 0
}

# Restart the *same* fixture without rewriting it — for persistence, which asks whether what reached
# disk comes back after a relaunch. The snapshot is cleared so a stale one can't masquerade as fresh.
relaunch_app() {
    quit_app
    sudo rm -f "$SNAPSHOT" 2>/dev/null || rm -f "$SNAPSHOT" 2>/dev/null || true
    if ! open_app; then fail "the app could not be relaunched"; return 1; fi
    if ! wait_for_snapshot; then fail "no fresh snapshot after relaunch"; dump_app_log; return 1; fi
    return 0
}

dump_app_log() {
    note "recent SiteBlocker log:"
    log show --last 2m --info --predicate 'subsystem == "com.pauljohnson.siteblocker"' 2>/dev/null \
        | tail -15 | while read -r line; do note "$line"; done || true
}

# --------------------------------------------------------------------------- #
# Assertions                                                                    #
# --------------------------------------------------------------------------- #

# The content-filter extension blocks a flow when sb-driver (using the snapshot's own membership
# logic) says the host is blocked, so asserting on the snapshot asserts on what the filter would do.
expect_blocked() {
    local verdict; verdict="$("$SB" check "$SNAPSHOT" "$1" 2>/dev/null)"
    if [ "$verdict" = "blocked" ]; then pass "$2"; else fail "$2 (got '$verdict' for $1)"; fi
}

expect_allowed() {
    local verdict; verdict="$("$SB" check "$SNAPSHOT" "$1" 2>/dev/null)"
    if [ "$verdict" = "allowed" ]; then pass "$2"; else fail "$2 (got '$verdict' for $1)"; fi
}

expect_count() {
    local actual; actual="$("$SB" count "$SNAPSHOT" 2>/dev/null)"
    if [ "$actual" = "$1" ]; then pass "$2"; else fail "$2 (expected $1 blocked, got $actual)"; fi
}

expect_in_lists() {
    if grep -qF "$1" "$LISTS" 2>/dev/null; then pass "$2"; else fail "$2 (not in lists.json)"; fi
}

assert_app_running() {
    if pgrep -x SiteBlocker >/dev/null 2>&1; then pass "$1"; else fail "$1 (process not running)"; fi
}
