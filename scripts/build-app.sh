#!/bin/bash
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-release}"
if [[ "$configuration" != release && "$configuration" != debug ]]; then
  echo 'Usage: bash scripts/build-app.sh [release|debug]' >&2
  exit 1
fi
swift build --package-path "$project" -c "$configuration"
bin="$(swift build --package-path "$project" -c "$configuration" --show-bin-path)"
app="$project/dist/Tiny Usage.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$bin/TinyUsage" "$app/Contents/MacOS/TinyUsage"
cp "$bin/TinyUsageCapture" "$app/Contents/Helpers/TinyUsageCapture"
# Flatten the assets for AppKit's Bundle.main lookup, and retain the SwiftPM bundle.
ditto "$project/Sources/Mimir/Resources" "$app/Contents/Resources"
for bundle in "$bin"/*_Mimir.bundle; do
  if [[ -d "$bundle" ]]; then ditto "$bundle" "$app/Contents/Resources/$(basename "$bundle")"; fi
done
cp "$project/LICENSE" "$app/Contents/Resources/Mimir-LICENSE.txt"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TinyUsage</string>
<key>CFBundleIdentifier</key><string>dev.tinyusage.macos</string>
<key>CFBundleName</key><string>Tiny Usage</string>
<key>CFBundleDisplayName</key><string>Tiny Usage</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Tiny Usage</string><key>CFBundleURLSchemes</key><array><string>tinyusage</string></array></dict></array>
</dict></plist>
PLIST
codesign --force --sign "${SIGN_IDENTITY:--}" "$app/Contents/Helpers/TinyUsageCapture"
codesign --force --sign "${SIGN_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
echo "$app"
