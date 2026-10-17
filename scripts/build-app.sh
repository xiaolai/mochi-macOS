#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# VERSION is the only place the release number lives; the parser validates it.
versions=$(python3 scripts/release_support.py version VERSION)
read -r MOCHI_VERSION MOCHI_BUILD <<< "$versions"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
if [ "${MOCHI_DISTRIBUTION:-0}" = 1 ]; then
    # The compiler lists every interface string it sees; only this build has exactly the shipped ones, since
    # development builds add probe text.
    STRINGS="$PWD/.build/localized-strings"
    swift build -c release -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$STRINGS" \
        -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION"
    python3 scripts/localization.py check "$STRINGS"
else
    swift build -c release -Xswiftc -DMOCHI_DEVELOPMENT -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION"
fi
BIN="$(swift build -c release --show-bin-path)"
APP="${MOCHI_APP_PATH:-$PWD/build/Mochi.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Mochi" "$APP/Contents/MacOS/Mochi"
cp "$BIN/mochi-mcp" "$APP/Contents/MacOS/mochi-mcp"
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
# macOS takes the app's languages, its menus' language and InfoPlist.strings from the main bundle, and the
# interface looks its strings up there too. The catalogs are compiled here rather than by the package build,
# which compiles them on some toolchains and silently skips them on others.
read -r -a LANGUAGES <<< "$(python3 scripts/localization.py languages)"
mkdir -p "$APP/Contents/Resources/en.lproj"
for catalog in Localizable InfoPlist; do
    xcrun xcstringstool compile "Localization/$catalog.xcstrings" --output-directory "$APP/Contents/Resources"
    for language in "${LANGUAGES[@]}"; do
        [ -s "$APP/Contents/Resources/$language.lproj/$catalog.strings" ] || { echo "Missing $language $catalog.strings" >&2; exit 1; }
    done
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Mochi</string>
<key>CFBundleDisplayName</key><string>Mochi</string>
<key>CFBundleIdentifier</key><string>com.lixiaolai.mochi-macos</string>
<key>CFBundleExecutable</key><string>Mochi</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>@VERSION@</string>
<key>CFBundleVersion</key><string>@BUILD@</string>
<key>MochiSingleInstanceProtocol</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>com.lixiaolai.mochi-macos.library</string>
<key>UTTypeDescription</key><string>Mochi Library Backup</string>
<key>UTTypeConformsTo</key><array><string>com.apple.package</string></array>
<key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>mochilibrary</string><string>enjoylibrary</string></array></dict>
</dict></array>
<key>NSMicrophoneUsageDescription</key><string>Record a voice message for Mochi or a practice attempt. Practice recordings stay on your Mac.</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MOCHI_VERSION" -c "Set :CFBundleVersion $MOCHI_BUILD" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string en" -c "Add :CFBundleLocalizations array" \
    -c "Add :CFBundleLocalizations:0 string en" "$APP/Contents/Info.plist"
for language in "${LANGUAGES[@]}"; do
    /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations: string $language" "$APP/Contents/Info.plist"
done
if [ "${MOCHI_DISTRIBUTION:-0}" = 1 ] && [ "${MOCHI_ADHOC_DISTRIBUTION:-0}" = 1 ]; then
    # CI builds the shipped configuration without a Developer ID: signed ad hoc, so it can be checked but never
    # shipped. release.sh refuses this variable and verifies the Developer ID signature it needs.
    codesign --force --options runtime --timestamp=none --sign - "$APP/Contents/MacOS/mochi-mcp"
    codesign --force --options runtime --timestamp=none --entitlements scripts/release-entitlements.plist --sign - "$APP"
elif [ "${MOCHI_DISTRIBUTION:-0}" = 1 ]; then
    : "${MOCHI_SIGN_ID:?Distribution requires MOCHI_SIGN_ID}"
    [ "$MOCHI_SIGN_ID" != - ] || { echo "Distribution cannot use ad-hoc signing" >&2; exit 1; }
    codesign --force --options runtime --timestamp --sign "$MOCHI_SIGN_ID" "$APP/Contents/MacOS/mochi-mcp"
    codesign --force --options runtime --timestamp --entitlements scripts/release-entitlements.plist --sign "$MOCHI_SIGN_ID" "$APP"
else
    codesign --force --sign - "$APP/Contents/MacOS/mochi-mcp"
    codesign --force --sign - "$APP"
fi
codesign --verify --strict --deep "$APP"
printf 'Built %s\n' "$APP"
