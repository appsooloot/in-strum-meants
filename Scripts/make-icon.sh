#!/bin/bash
# Renders Packaging/AppIcon.svg into an .icns at every macOS size.
# Usage: Scripts/make-icon.sh <output.icns>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?output .icns path required}"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  rsvg-convert -w $s -h $s "$ROOT/Packaging/AppIcon.svg" -o "$SET/icon_${s}x${s}.png"
  rsvg-convert -w $((s * 2)) -h $((s * 2)) "$ROOT/Packaging/AppIcon.svg" -o "$SET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$SET" -o "$OUT"
