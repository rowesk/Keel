#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${KEEL_VERIFY_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/keel-verify.XXXXXX")}"
case "$BUILD_ROOT" in
  "$ROOT_DIR"|"$ROOT_DIR"/*)
    print -u2 "KEEL_VERIFY_ROOT must be outside the source checkout."
    exit 1
    ;;
esac
mkdir -p "$BUILD_ROOT"
cd "$ROOT_DIR"
# An unattended gate never opts into desktop interaction or baseline recording.
KEEL_ALLOW_FOREGROUND_TESTS=0 KEEL_RECORD_SNAPSHOTS=0 \
  swift test --scratch-path "$BUILD_ROOT/tests" -Xswiftc -warnings-as-errors
KEEL_BUILD_ROOT="$BUILD_ROOT/release" "$ROOT_DIR/Scripts/build.sh"
git diff --check
print "PASS verification: tests, snapshot comparisons, signed release and whitespace checks"
