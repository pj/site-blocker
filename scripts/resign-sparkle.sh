#!/usr/bin/env bash
# Re-sign Sparkle.framework's nested helper binaries with our Developer ID cert + hardened runtime
# + secure timestamp, then re-seal the app over them.
#
# Why this is needed: Xcode embeds Sparkle already signed by the Sparkle project and does NOT
# re-sign its deeply nested executables (Updater.app, Autoupdate, Downloader.xpc, Installer.xpc).
# Notarization then rejects the whole archive with, for each of those binaries:
#   "The binary is not signed with a valid Developer ID certificate."
#   "The signature does not include a secure timestamp."
# We fix them inside-out (helpers → framework → app). The app must be re-sealed afterwards because
# modifying the framework's contents invalidates the app's outer signature.
#
# Usage: resign-sparkle.sh <path-to-.app> <codesign-identity>
set -euo pipefail

app="$1"
identity="$2"
fw="$app/Contents/Frameworks/Sparkle.framework"

if [ ! -d "$fw" ]; then
    echo "resign-sparkle: no Sparkle.framework in $app — nothing to do" >&2
    exit 0
fi

# The source App/SiteBlocker.entitlements uses $(TeamIdentifierPrefix), which Xcode expands at build
# time. Re-signing with that raw file would embed the literal string, so instead we preserve the
# app's already-expanded entitlements by reading them back out of the built binary.
ent="$(mktemp -t sb_app_ent).plist"
trap 'rm -f "$ent"' EXIT
codesign -d --entitlements - --xml "$app" 2>/dev/null > "$ent"

# Inside-out: nested helpers first, then the framework bundle itself.
for item in \
    "$fw/Versions/B/XPCServices/Downloader.xpc" \
    "$fw/Versions/B/XPCServices/Installer.xpc" \
    "$fw/Versions/B/Autoupdate" \
    "$fw/Versions/B/Updater.app"; do
    codesign --force --options runtime --timestamp --sign "$identity" "$item"
done
codesign --force --options runtime --timestamp --sign "$identity" "$fw"

# Re-seal the app over the re-signed framework. No --deep: the embedded system extension keeps its
# own signature + entitlements and is sealed by cdhash.
codesign --force --options runtime --timestamp \
    --entitlements "$ent" --sign "$identity" "$app"

codesign --verify --deep --strict "$app"
echo "resign-sparkle: re-signed Sparkle helpers and re-sealed $(basename "$app")"
