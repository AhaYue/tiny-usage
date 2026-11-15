#!/bin/bash
# Regenerate Assets/AppIcon.icns from Assets/AppIcon.svg (sips + iconutil, no Xcode project needed).
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/tiny-usage-icon.XXXXXX")"
trap 'rm -rf "$work"' EXIT
sips -s format png "$project/Assets/AppIcon.svg" --out "$work/1024.png" >/dev/null
iconset="$work/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$work/1024.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$work/1024.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$project/Assets/AppIcon.icns"
echo "$project/Assets/AppIcon.icns"
