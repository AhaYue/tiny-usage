#!/bin/bash
# Package dist/Tiny Usage.app (run build-app.sh first) for a release:
#   dist/TinyUsage-<version>.zip  what Sparkle downloads (ditto keeps symlinks and signatures)
#   dist/TinyUsage-<version>.dmg  first install: drag the app onto Applications
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
app="$project/dist/Tiny Usage.app"
[[ -d "$app" ]] || { echo "build the app first: bash scripts/build-app.sh" >&2; exit 1; }
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
zip="$project/dist/TinyUsage-$version.zip"
dmg="$project/dist/TinyUsage-$version.dmg"
rm -f "$zip" "$dmg"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Tiny Usage.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "Tiny Usage" -srcfolder "$stage" -fs HFS+ -format ULMO -ov "$dmg"
echo "$zip"
echo "$dmg"
