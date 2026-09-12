#!/usr/bin/env bash
# Content-filter blocking: does the snapshot the app resolves actually deny a listed domain (and its
# subdomains), leave an unlisted one alone, and flip to allowed when the list is opened?
#
# The snapshot is the filter's whole input: the extension blocks a flow iff the SNI host matches a
# blocked pattern by the same suffix rule sb-driver applies here. So these assertions are exactly the
# allow/deny verdicts the installed filter would return for those hostnames.
#
# NOTE: this verifies the decision the filter makes from the app's output, not a live packet drop —
# installing the NEFilter system extension needs sysext approval, which a SIP-on VM cannot do
# headlessly. See vm/README.md "What this does and does not prove".

info "Content filter: a blocked-by-default list denies its targets"
launch_scenario "blocked-basic" || return 0

expect_blocked "example.com"      "the listed domain is blocked"
expect_blocked "www.example.com"  "a subdomain of the listed domain is blocked"
expect_blocked "tracker.test"     "a second listed domain is blocked"
expect_allowed "allowed.test"     "an unlisted domain is allowed"
expect_allowed "notexample.com"   "a look-alike that is not a subdomain is allowed"

info "Content filter: opening the list (always-allow exception) lets the targets through"
launch_scenario "allow-always" || return 0

expect_allowed "example.com"  "the once-blocked domain is now allowed"
expect_allowed "tracker.test" "the second domain is now allowed too"
expect_count   "0"            "nothing is blocked while the list is open"
