#!/usr/bin/env bash
# Ritar om ikonen och bygger icon/AppIcon.icns från make_icon.swift.
set -euo pipefail
cd "$(dirname "$0")"
TMP=$(mktemp -d)
swift make_icon.swift "$TMP/icon_1024.png" torpet.jpg
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o AppIcon.icns
cp "$TMP/icon_1024.png" icon.png
rm -rf "$TMP"
echo "Byggde icon/AppIcon.icns"
