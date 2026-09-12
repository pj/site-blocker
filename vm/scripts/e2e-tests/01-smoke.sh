#!/usr/bin/env bash
# Smoke: the app, built on the host and copied in, actually launches in the VM and runs its pipeline
# far enough to resolve a snapshot to the shared path the extension reads. If this fails nothing else
# can pass, so it runs first and says so plainly.

info "Smoke: the app launches and resolves a snapshot"
launch_scenario "blocked-basic" || return 0

assert_app_running "SiteBlocker is running after launch"

if [ -f "$SNAPSHOT" ]; then
    pass "the policy snapshot was written to the shared path"
    note "snapshot: $SNAPSHOT  ($("$SB" count "$SNAPSHOT") blocked pattern(s))"
else
    fail "no policy snapshot at $SNAPSHOT"
fi
