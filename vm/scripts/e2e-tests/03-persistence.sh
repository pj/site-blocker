#!/usr/bin/env bash
# Persistence: a list added in one run is still there in the next, and the snapshot the extension
# reads is rebuilt correctly from it.
#
# Relaunched, not reopened-in-process: the point is that what reached lists.json on disk is what the
# app loads next time. So these assert against lists.json itself and against a snapshot written by a
# second, separate launch.

MARKER="E2E Persist Marker"

info "Persistence: a new list reaches disk and blocks"
launch_scenario "persistence" || return 0

expect_in_lists "$MARKER"    "the list name reached lists.json"
expect_blocked  "example.com" "its target is blocked in this run's snapshot"

info "Persistence: it survives a relaunch"
# No rewrite — relaunch_app reloads whatever is on disk, which is the whole test.
relaunch_app || return 0

expect_in_lists "$MARKER"     "the list is still in lists.json after relaunch"
expect_blocked  "example.com"  "the relaunched app rebuilt a snapshot that still blocks it"
expect_blocked  "www.example.com" "subdomain matching still holds after relaunch"
