#!/bin/bash
# Fast UI check: debug-build the bare binary (incremental, no .app, no signing, no restart) and
# render the real SwiftUI views to PNGs with demo data. Usage:
#   bash scripts/preview.sh            # all states → .build/previews/
#   bash scripts/preview.sh panel      # only files whose name contains "panel"
#   PREVIEW_LANG=en bash scripts/preview.sh   # in English (or zh-Hans); default is the system language
# Outputs: panel-*, settings-*, waiting-first-data-*, waiting-update-*, saved-data-*,
#          login-expired-*, rate-limited-* (each -dark/-light) and menu-bar.png.
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
out="$project/.build/previews"
swift build --package-path "$project" --product TinyUsage 2>&1 | grep -E 'error|warning: unre|Build complete' || true
bin="$(swift build --package-path "$project" --show-bin-path)"
# The .app embeds Sparkle; the bare binary needs to be pointed at it.
sparkle_dir="$(dirname "$(find "$project/.build/artifacts" -path '*macos*' -name Sparkle.framework -type d | head -1)")"
# A minimal bundle so Bundle.main finds the .lproj strings and icons exactly as the real .app does.
# Resources is a symlink to the sources, so string and icon edits show up without copying.
shell="$project/.build/preview-shell/Tiny Usage Preview.app/Contents"
mkdir -p "$shell/MacOS"
cp "$bin/TinyUsage" "$shell/MacOS/TinyUsage"
ln -sfn "$project/Sources/TinyUsageCore/Resources" "$shell/Resources"
cat > "$shell/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TinyUsage</string>
<key>CFBundleIdentifier</key><string>dev.tinyusage.preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
rm -rf "$out"; mkdir -p "$out"
language=()
if [[ -n "${PREVIEW_LANG:-}" ]]; then language=(-AppleLanguages "($PREVIEW_LANG)"); fi
PREVIEW_ONLY="${1:-}" DYLD_FRAMEWORK_PATH="$sparkle_dir" \
  "$shell/MacOS/TinyUsage" --render-preview "$out/preview.png" ${language[@]+"${language[@]}"}
ls "$out"/*.png
