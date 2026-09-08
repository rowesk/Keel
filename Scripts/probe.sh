#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${KEEL_BUILD_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/keel-production-probe.XXXXXX")}"

case "$BUILD_ROOT" in
  "$ROOT_DIR"|"$ROOT_DIR"/*)
    print -u2 "KEEL_BUILD_ROOT must be outside the source checkout."
    exit 1
    ;;
esac

APP_PATH="$(KEEL_BUILD_ROOT="$BUILD_ROOT" "$ROOT_DIR/Scripts/build.sh")"
PLIST="$APP_PATH/Contents/Info.plist"

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" == "com.chrisrowe.keel" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")" == "26.0" ]]
codesign --verify --strict --verbose=2 "$APP_PATH"
SIGNATURE_DETAILS="$(codesign -dvvv "$APP_PATH" 2>&1)"
[[ "$SIGNATURE_DETAILS" == *"runtime"* ]]
[[ "$SIGNATURE_DETAILS" == *"Authority=Apple Development:"* ]]
[[ "$SIGNATURE_DETAILS" == *"TeamIdentifier="* ]]
[[ "$SIGNATURE_DETAILS" != *"TeamIdentifier=not set"* ]]
ENTITLEMENTS="$(codesign -d --entitlements :- "$APP_PATH" 2>&1 | sed -n '/<?xml/,$p' | plutil -p -)"
for ENTITLEMENT in \
  com.apple.security.app-sandbox \
  com.apple.security.network.client \
  com.apple.security.print \
  com.apple.security.files.downloads.read-write \
  com.apple.security.files.user-selected.read-write; do
  [[ "$ENTITLEMENTS" == *\"$ENTITLEMENT\"\ \=\>\ true* ]]
done

PROBE_TOKEN="$(uuidgen)"
KEEL_PROBE_PHASE=write KEEL_PROBE_TOKEN="$PROBE_TOKEN" \
    "$APP_PATH/Contents/MacOS/Keel" --probe

APP_PATH="$(KEEL_BUILD_ROOT="$BUILD_ROOT" "$ROOT_DIR/Scripts/build.sh")"
KEEL_PROBE_PHASE=verify KEEL_PROBE_TOKEN="$PROBE_TOKEN" \
    "$APP_PATH/Contents/MacOS/Keel" --probe

print "PASS bundle: development-signed production app stayed offscreen across replacement"
