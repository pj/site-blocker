#!/usr/bin/env bash
# e2e-test.sh — run the end-to-end scenarios. Runs *inside* the VM, in the logged-in GUI session
# (vm/run-e2e.sh launches it through `launchctl asuser`, because the app needs an Aqua session).
#
# Usage (normally invoked by vm/run-e2e.sh):
#   PROJECT_DIR=~/Projects/site_blocker ~/Projects/site_blocker/vm/scripts/e2e-test.sh           # all
#   PROJECT_DIR=~/Projects/site_blocker ~/Projects/site_blocker/vm/scripts/e2e-test.sh 02        # one

set -uo pipefail

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "$PROJECT_DIR/vm/scripts/e2e-lib.sh"

info "Checking the build arrived from the host"
if [ ! -d "$APP" ]; then
    echo "no app bundle at $APP — it is built on the host; run through vm/run-e2e.sh." >&2
    exit 1
fi
if [ ! -x "$SB" ]; then
    echo "no sb-driver at $SB — it is built on the host; run through vm/run-e2e.sh." >&2
    exit 1
fi

trap 'quit_app' EXIT

only="${1:-}"
failed_files=()

for file in "$PROJECT_DIR"/vm/scripts/e2e-tests/*.sh; do
    name="$(basename "$file" .sh)"
    if [ -n "$only" ] && [[ "$name" != *"$only"* ]]; then continue; fi
    echo
    echo "───────────────────────────────────────────── $name"
    before=$FAIL_COUNT
    # shellcheck disable=SC1090
    source "$file" || fail "$name exited unexpectedly"
    if [ "$FAIL_COUNT" -gt "$before" ]; then failed_files+=("$name"); fi
done

echo
echo "───────────────────────────────────────────────────────"
echo "passed: $PASS_COUNT   failed: $FAIL_COUNT"
if [ ${#failed_files[@]} -gt 0 ]; then
    echo "failing files: ${failed_files[*]}"
fi
[ "$FAIL_COUNT" -eq 0 ]
