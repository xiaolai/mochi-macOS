#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
swift build -c release -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION"
BIN="$(swift build -c release --show-bin-path)"
APP="${MOCHI_APP_PATH:-$PWD/build/Mochi.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Mochi" "$APP/Contents/MacOS/Mochi"
cp Sources/MochiApp/Resources/AppIcon.png "$APP/Contents/Resources/AppIcon.png"
ICON_WORK="$(mktemp -d "${TMPDIR:-/tmp}/mochi-icon.XXXXXX")"
trap 'rm -rf "$ICON_WORK"' EXIT
mkdir -p "$ICON_WORK/AppIcon.iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Sources/MochiApp/Resources/AppIcon.png --out "$ICON_WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" Sources/MochiApp/Resources/AppIcon.png --out "$ICON_WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
for bundle in "$BIN"/*.bundle; do
    if [ -d "$bundle" ]; then cp -R "$bundle" "$APP/Contents/Resources/"; fi
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Mochi</string>
<key>CFBundleDisplayName</key><string>Mochi</string>
<key>CFBundleIdentifier</key><string>com.xiaolai.mochi-macos</string>
<key>CFBundleExecutable</key><string>Mochi</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.2</string>
<key>CFBundleVersion</key><string>24</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>com.xiaolai.mochi-macos.library</string>
<key>UTTypeDescription</key><string>Mochi Library Backup</string>
<key>UTTypeConformsTo</key><array><string>com.apple.package</string></array>
<key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>mochilibrary</string><string>enjoylibrary</string></array></dict>
</dict></array>
<key>NSMicrophoneUsageDescription</key><string>Record a voice message for Mochi or a practice attempt. Practice recordings stay on your Mac.</string>
</dict></plist>
PLIST
if [ "${MOCHI_DISTRIBUTION:-0}" = 1 ]; then
    : "${MOCHI_SIGN_ID:?Distribution requires MOCHI_SIGN_ID}"
    [ "$MOCHI_SIGN_ID" != - ] || { echo "Distribution cannot use ad-hoc signing" >&2; exit 1; }
    codesign --force --options runtime --timestamp --entitlements scripts/release-entitlements.plist --sign "$MOCHI_SIGN_ID" "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign --verify --strict --deep "$APP"
printf 'Built %s\n' "$APP"
