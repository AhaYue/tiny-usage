#!/bin/bash
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-release}"
if [[ "$configuration" != release && "$configuration" != debug ]]; then
  echo 'Usage: bash scripts/build-app.sh [release|debug]' >&2
  exit 1
fi
flags=()
# Release: optimise for size; the app does little compute, so smaller code costs nothing noticeable.
if [[ "$configuration" == release ]]; then flags=(-Xswiftc -Osize); fi
swift build --package-path "$project" -c "$configuration" ${flags[@]+"${flags[@]}"}
bin="$(swift build --package-path "$project" -c "$configuration" ${flags[@]+"${flags[@]}"} --show-bin-path)"
app="$project/dist/Tiny Usage.app"
# Version: $VERSION (CI passes the tag), else the latest v* tag, else 0.1.0.
version="${VERSION:-$(git -C "$project" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo v0.1.0)}"
version="${version#v}"
build_number="$(bash "$project/scripts/build_number.sh" "$version")"
# Sparkle feed and the public half of the update-signing key. FEED_URL overrides the feed for
# local update tests only.
feed_url="${FEED_URL:-https://raw.githubusercontent.com/AhaYue/tiny-usage/main/appcast.xml}"
public_ed_key="4iKZ2HP1oEu01zXiOM0SufdNdcDtRFWZuoD94bHMVCI="
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$bin/TinyUsage" "$app/Contents/MacOS/TinyUsage"
cp "$bin/TinyUsageCapture" "$app/Contents/Helpers/TinyUsageCapture"
if [[ "$configuration" == release ]]; then
  strip -x "$app/Contents/MacOS/TinyUsage" "$app/Contents/Helpers/TinyUsageCapture"
fi
# Flatten the assets for AppKit's Bundle.main lookup. The SwiftPM bundle would only duplicate
# them, and MenuIcon.png (1024px source art) isn't loaded by the app, so neither is shipped.
rsync -a --exclude MenuIcon.png "$project/Sources/TinyUsageCore/Resources/" "$app/Contents/Resources/"
# Sparkle. The app isn't sandboxed, so the XPC services (only needed by sandboxed hosts) stay out.
sparkle="$(find "$project/.build/artifacts" -path '*macos*' -name Sparkle.framework -type d | head -1)"
[[ -n "$sparkle" ]] || { echo "Sparkle.framework not found; run swift package resolve" >&2; exit 1; }
ditto --norsrc "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"
# Headers and module maps are for compiling against the framework, not for running it.
for extra in XPCServices Headers PrivateHeaders Modules; do
  rm -rf "$app/Contents/Frameworks/Sparkle.framework/Versions/B/$extra" "$app/Contents/Frameworks/Sparkle.framework/$extra"
done
cp "$project/LICENSE" "$app/Contents/Resources/LICENSE.txt"
cp "$project/Assets/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TinyUsage</string>
<key>CFBundleIdentifier</key><string>dev.tinyusage.macos</string>
<key>CFBundleName</key><string>Tiny Usage</string>
<key>CFBundleDisplayName</key><string>Tiny Usage</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>SUFeedURL</key><string>$feed_url</string>
<key>SUPublicEDKey</key><string>$public_ed_key</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Tiny Usage</string><key>CFBundleURLSchemes</key><array><string>tinyusage</string></array></dict></array>
</dict></plist>
PLIST
xattr -cr "$app"
sign() { codesign --force --sign "${SIGN_IDENTITY:--}" "$@"; }
# Inside out: Sparkle's nested helpers, the framework, our helper, then the app.
sparkle_b="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$sparkle_b/Updater.app"
sign "$sparkle_b/Autoupdate"
sign "$app/Contents/Frameworks/Sparkle.framework"
sign "$app/Contents/Helpers/TinyUsageCapture"
sign "$app"
codesign --verify --strict "$app"
echo "$app"
