#!/bin/bash
# Builds the drag-to-install disk image from dist/In Strum Meants.app.
# Usage: Scripts/make-dmg.sh <build-number>
set -euo pipefail
BUILD="${1:?build number required}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/In Strum Meants.app"
WORK="$(mktemp -d)"
rsvg-convert -w 660 -h 400 "$ROOT/Packaging/dmg-background.svg" -o "$WORK/bg.png"
rsvg-convert -w 1320 -h 800 "$ROOT/Packaging/dmg-background.svg" -o "$WORK/bg@2x.png"
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/background.tiff"
dmgbuild -s "$ROOT/Packaging/dmg_settings.py" -D app="$APP" -D background="$WORK/background.tiff" \
  "In Strum Meants" "$ROOT/dist/In-Strum-Meants-build-$BUILD.dmg"
echo "$ROOT/dist/In-Strum-Meants-build-$BUILD.dmg"
