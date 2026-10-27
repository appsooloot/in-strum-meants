#!/bin/bash
# Builds "In Strum Meants.app" for Intel Macs (macOS 13+) and zips it.
# Usage: Scripts/make-app.sh <build-number>
set -euo pipefail
BUILD="${1:?build number required}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/In Strum Meants.app"
ZIP="$ROOT/dist/In-Strum-Meants-build-$BUILD.zip"

cd "$ROOT"
swift build -c release --arch x86_64 --product InStrumMeants
BIN="$(swift build -c release --arch x86_64 --show-bin-path)/InStrumMeants"

rm -rf "$ROOT/dist"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/InStrumMeants"
sed "s/__BUILD__/$BUILD/g" "$ROOT/Packaging/Info.plist" > "$APP/Contents/Info.plist"
codesign --force --deep -s - "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "$ZIP"
