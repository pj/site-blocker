#!/usr/bin/env bash
# Exception activation: an exception flips a list's base state only while its condition holds. Each
# scenario below differs only in the exception, so the snapshot verdict isolates the condition.
#
# The schedule windows are computed against the VM's own clock (sb-driver builds a window that
# covers "now" for the active case and one two hours out for the inactive case), so "during the
# window" and "outside it" are real, not faked.

info "Exception: an allow window covering now opens the list"
launch_scenario "schedule-active" || return 0
expect_allowed "example.com" "a schedule exception active now makes the target allowed"

info "Exception: the same window, outside its hours, leaves the list blocked"
launch_scenario "schedule-inactive" || return 0
expect_blocked "example.com" "a schedule exception inactive now leaves the target blocked"

info "Exception: an always-on allow exception opens the list"
launch_scenario "allow-always" || return 0
expect_allowed "example.com" "an unconditional allow exception makes the target allowed"

info "Exception: a location exception stays shut without the location signal"
# The app resolves insideRegionIDs from Core Location. Headless, with no fix for this region, the
# signal is absent, so the exception must NOT open the list — proving signal-gated exceptions are
# truly gated. The active-signal case (seeding a fix / a calendar event) is future work; see
# vm/README.md.
launch_scenario "location-no-signal" || return 0
expect_blocked "example.com" "an at-location exception does not open the list with no location fix"
