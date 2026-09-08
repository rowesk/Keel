#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${KEEL_BUILD_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/keel-production-build.XXXXXX")}"
SIGN_IDENTITY="${KEEL_SIGN_IDENTITY:-}"

if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(
        security find-identity -v -p codesigning \
            | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' \
            | head -n 1
    )"
fi

if [[ -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == "-" ]]; then
    print -u2 "Keel production builds require an Apple Development signing identity."
    print -u2 "Set KEEL_SIGN_IDENTITY or install an Apple Development certificate."
    exit 1
fi

case "$BUILD_ROOT" in
  "$ROOT_DIR"|"$ROOT_DIR"/*)
    print -u2 "KEEL_BUILD_ROOT must be outside the source checkout."
    exit 1
    ;;
esac

mkdir -p "$BUILD_ROOT"
SCRATCH_PATH="$BUILD_ROOT/swiftpm"
APP_PATH="$BUILD_ROOT/Keel.app"

cd "$ROOT_DIR"
swift build --configuration release --scratch-path "$SCRATCH_PATH" --product Keel -Xswiftc -warnings-as-errors >&2
BIN_PATH="$(swift build --configuration release --scratch-path "$SCRATCH_PATH" --product Keel --show-bin-path)/Keel"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH" "$APP_PATH/Contents/MacOS/Keel"
cp "$ROOT_DIR/Supporting/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$ROOT_DIR/Supporting/Keel.icns" "$APP_PATH/Contents/Resources/Keel.icns"

# SwiftPM emits target resource bundles beside the binary. Bundle.module looks
# for them in Contents/Resources once the binary lives in an app wrapper.
BIN_DIR="$(dirname "$BIN_PATH")"
for bundle in "$BIN_DIR"/*.bundle(N); do
    cp -R "$bundle" "$APP_PATH/Contents/Resources/"
done

# Record the exact inputs, including local edits, before sealing the bundle.
python3 "$ROOT_DIR/Scripts/build-provenance.py" "$ROOT_DIR" \
    "$APP_PATH/Contents/Resources/KeelBuild.json"
xattr -cr "$APP_PATH"

codesign \
  --force \
  --sign "$SIGN_IDENTITY" \
  --options runtime \
  --entitlements "$ROOT_DIR/Supporting/Keel.entitlements" \
  --timestamp=none \
  "$APP_PATH"
codesign --verify --strict --verbose=2 "$APP_PATH" >&2

print -- "$APP_PATH"
