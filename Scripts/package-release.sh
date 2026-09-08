#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${KEEL_DEVELOPER_ID:-}" || "$KEEL_DEVELOPER_ID" != 'Developer ID Application:'* ]]; then
  print -u2 'Set KEEL_DEVELOPER_ID to an installed Developer ID Application signing identity.'
  exit 1
fi
if [[ -z "${KEEL_NOTARY_PROFILE:-}" ]]; then
  print -u2 'Set KEEL_NOTARY_PROFILE to a notarytool keychain profile. Never put credentials in this repository.'
  exit 1
fi
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
  print -u2 'Commit the exact release source before packaging.'
  exit 1
fi

RELEASE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/keel-distribution.XXXXXX")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Supporting/Info.plist")"
ARCH="$(uname -m)"
if [[ "$ARCH" != arm64 ]]; then
  print -u2 'Public packaging currently supports the tested arm64 build only.'
  exit 1
fi

APP_PATH="$(KEEL_BUILD_ROOT="$RELEASE_ROOT/build" KEEL_SIGN_IDENTITY="$KEEL_DEVELOPER_ID" "$ROOT_DIR/Scripts/build.sh")"
codesign --force --sign "$KEEL_DEVELOPER_ID" --options runtime --timestamp \
  --entitlements "$ROOT_DIR/Supporting/Keel.entitlements" "$APP_PATH"
codesign --verify --strict --verbose=2 "$APP_PATH"

notarize() {
  local artifact="$1"
  local result="$2"
  xcrun notarytool submit "$artifact" --keychain-profile "$KEEL_NOTARY_PROFILE" \
    --wait --output-format json > "$result"
  python3 - "$result" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('Apple did not accept this artifact. Inspect the local notarization result and log before retrying.')
PY
}

# Staple the app before it enters the disk image, so both carry their tickets.
ditto -c -k --keepParent "$APP_PATH" "$RELEASE_ROOT/Keel-notarization.zip"
notarize "$RELEASE_ROOT/Keel-notarization.zip" "$RELEASE_ROOT/app-notarization.json"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"

mkdir "$RELEASE_ROOT/image"
ditto "$APP_PATH" "$RELEASE_ROOT/image/Keel.app"
ln -s /Applications "$RELEASE_ROOT/image/Applications"
DMG_PATH="$RELEASE_ROOT/Keel-$VERSION-$ARCH.dmg"
hdiutil create -volname Keel -srcfolder "$RELEASE_ROOT/image" -ov -format UDZO "$DMG_PATH"
codesign --sign "$KEEL_DEVELOPER_ID" --timestamp "$DMG_PATH"
notarize "$DMG_PATH" "$RELEASE_ROOT/dmg-notarization.json"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
codesign --verify --strict "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

python3 - "$DMG_PATH" <<'PY'
import hashlib, pathlib, sys
p = pathlib.Path(sys.argv[1])
p.with_suffix('.dmg.sha256').write_text(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n')
PY
print "Verified disk image: $DMG_PATH"
print 'Publish only the DMG and its checksum after clean-install acceptance. Keep notarization logs private.'
