#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${MOCHI_SIGN_ID:?Set a Developer ID Application signing identity}"
: "${MOCHI_NOTARY_PROFILE:?Set a notarytool Keychain profile}"
[ "$MOCHI_SIGN_ID" != - ] || { echo 'Ad-hoc signing cannot ship' >&2; exit 1; }
xcrun notarytool history --keychain-profile "$MOCHI_NOTARY_PROFILE" >/dev/null
swift test
python3 -m unittest discover -s scripts/tests
OUT="$PWD/build/release"
APP="$OUT/Mochi.app"
[ ! -e "$OUT/Mochi-${MOCHI_RELEASE_VERSION:-0.3.0}.dmg" ] || { echo 'Release DMG already exists; preserve it before rebuilding' >&2; exit 1; }
mkdir -p "$OUT"
MOCHI_DISTRIBUTION=1 MOCHI_APP_PATH="$APP" ./scripts/build-app.sh
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
python3 scripts/release_support.py metadata "$APP/Contents/Info.plist" "${MOCHI_RELEASE_VERSION:-0.3.0}" "${MOCHI_RELEASE_BUILD:-27}"
python3 scripts/release_support.py binary "$APP/Contents/MacOS/Mochi"
python3 scripts/release_support.py binary "$APP/Contents/MacOS/mochi-mcp"
python3 scripts/release_support.py distribution "$APP/Contents/MacOS/Mochi" "$APP/Contents/MacOS/mochi-mcp"
codesign -d --verbose=4 "$APP" 2> "$OUT/signature.txt"
grep -q 'Authority=Developer ID Application' "$OUT/signature.txt"
grep -q 'Timestamp=' "$OUT/signature.txt"
grep -q 'flags=.*runtime' "$OUT/signature.txt"
codesign -d --entitlements :- "$APP" > "$OUT/entitlements.plist" 2>/dev/null
[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "$OUT/entitlements.plist")" = true ]
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$OUT/entitlements.plist" >/dev/null 2>&1; then
    echo 'Debug entitlement cannot ship' >&2; exit 1
fi
staple() {
    for attempt in 1 2 3; do
        if xcrun stapler staple "$1"; then break; fi
        [ "$attempt" != 3 ] || return 1
        sleep 5
    done
    xcrun stapler validate "$1"
}
gatekeeper() {
    local artifact="$1" verdict
    shift
    verdict=$(spctl -a -vvv "$@" "$artifact" 2>&1) || { echo "$verdict" >&2; return 1; }
    grep -q 'source=Notarized Developer ID' <<< "$verdict"
    echo "$verdict"
}
ditto -c -k --keepParent "$APP" "$OUT/Mochi.zip"
python3 scripts/release_support.py notarize "$OUT/Mochi.zip" "$MOCHI_NOTARY_PROFILE"
staple "$APP"
codesign --verify --strict --deep "$APP"
gatekeeper "$APP" -t exec
staging=$(mktemp -d)
mount=""
cleanup() {
    if [ -n "$mount" ]; then hdiutil detach -quiet "$mount" || true; fi
    rm -rf "$staging"
}
trap cleanup EXIT
ditto "$APP" "$staging/Mochi.app"
ln -s /Applications "$staging/Applications"
dmg="$OUT/Mochi-$version.dmg"
hdiutil create -quiet -volname "Mochi $version" -srcfolder "$staging" -format UDZO "$dmg"
codesign --force --timestamp --sign "$MOCHI_SIGN_ID" "$dmg"
python3 scripts/release_support.py notarize "$dmg" "$MOCHI_NOTARY_PROFILE"
staple "$dmg"
gatekeeper "$dmg" -t open --context context:primary-signature
mount=$(mktemp -d)
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount" "$dmg"
codesign --verify --strict --deep "$mount/Mochi.app"
xcrun stapler validate "$mount/Mochi.app"
gatekeeper "$mount/Mochi.app" -t exec
python3 scripts/release_support.py metadata "$mount/Mochi.app/Contents/Info.plist" "$version" "$build"
hdiutil detach -quiet "$mount"
rmdir "$mount"
mount=""
shasum -a 256 "$dmg" > "$OUT/SHA256SUMS"
echo "Release verified: Mochi $version (build $build)"
