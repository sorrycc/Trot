#!/usr/bin/env bash
# Builds the Swift app, then assembles and ad-hoc signs build/Trot.app.
# Usage: scripts/bundle.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TROT_OUT:-$ROOT/build}"
APP="$OUT/Trot.app"
# Not dev.sorrycc.trot: macOS 26 keeps that id's menu bar item hidden on
# at least one Mac, and nothing short of a new id brings it back.
BUNDLE_ID="${TROT_BUNDLE_ID:-dev.sorrycc.trot.app}"
VERSION="${TROT_VERSION:-0.4.0}"

echo "==> swift build ($CONFIG)"
swift build --package-path "$ROOT/app" -c "$CONFIG" -Xlinker -dead_strip
SWIFT_OUT="$(swift build --package-path "$ROOT/app" -c "$CONFIG" --show-bin-path)"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SWIFT_OUT/Trot" "$APP/Contents/MacOS/Trot"
[ "$CONFIG" = "release" ] && strip -x "$APP/Contents/MacOS/Trot"
icon=""
if [ -f "$ROOT/app/Resources/Trot.icns" ]; then
    cp "$ROOT/app/Resources/Trot.icns" "$APP/Contents/Resources/Trot.icns"
    icon="<key>CFBundleIconFile</key><string>Trot</string>"
fi

cp "$ROOT/app/Resources/MenuBarIcon.png" "$ROOT/app/Resources/MenuBarIcon@2x.png" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Trot</string>
    <key>CFBundleDisplayName</key><string>Trot</string>
    <key>CFBundleExecutable</key><string>Trot</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
    $icon
</dict>
</plist>
PLIST

echo "==> ad-hoc signing"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "==> done: $APP ($(du -sh "$APP" | cut -f1))"
