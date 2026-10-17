#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${MOCHI_SIGN_ID:?Set a Developer ID Application signing identity}"
: "${MOCHI_NOTARY_PROFILE:?Set a notarytool Keychain profile}"
[ "$MOCHI_SIGN_ID" != - ] || { echo 'Ad-hoc signing cannot ship' >&2; exit 1; }
[ "${MOCHI_ADHOC_DISTRIBUTION:-0}" = 0 ] || { echo 'MOCHI_ADHOC_DISTRIBUTION is for CI checks and cannot ship' >&2; exit 1; }
# MOCHI_RESUME_DMG=1 continues an unfinished run from its existing DMG, so a notarization retry reuses the submission.
resume="${MOCHI_RESUME_DMG:-0}"
OUT="$PWD/build/release"
APP="$OUT/Mochi.app"
LOCK="$OUT/.release.lock"
locked="" staging="" mountpoint="" attached="" version_file=""
cleanup() {
    if [ -n "$attached" ]; then
        hdiutil detach -quiet "$mountpoint" || { echo "Could not detach $mountpoint; detach it manually" >&2; mountpoint=""; }
    fi
    if [ -n "$mountpoint" ]; then rmdir "$mountpoint" || true; fi
    if [ -n "$staging" ]; then rm -rf "$staging"; fi
    if [ -n "$version_file" ]; then rm -f "$version_file"; fi
    if [ -n "$locked" ]; then rmdir "$LOCK" || true; fi
}
trap cleanup EXIT
mkdir -p "$OUT"
# Concurrent runs would share the app, archives, notary records and checksums.
mkdir "$LOCK" 2>/dev/null || { echo "Another release is running; remove $LOCK if it is stale" >&2; exit 1; }
locked=1
# Every later step uses this snapshot, so editing VERSION mid-run cannot pair a new version with this DMG.
version_file=$(mktemp)
cp VERSION "$version_file"
versions=$(python3 scripts/release_support.py version "$version_file")
read -r version build <<< "$versions"
# The build reads the working tree, so only a clean HEAD is released; a v<version> tag, if one exists, must name it.
head=$(python3 scripts/release_support.py source "$version")
dmg="$OUT/Mochi-$version.dmg"
# SHA256SUMS is written last, so naming this DMG means an earlier run finished and may have been published.
if [ -f "$OUT/SHA256SUMS" ] && grep -qx "[0-9a-f]\{64\}  $(basename "$dmg")" "$OUT/SHA256SUMS"; then
    echo 'Release DMG already verified; preserve it before rebuilding' >&2; exit 1
fi
if [ "$resume" = 1 ]; then
    [ -f "$dmg" ] || { echo "No unfinished DMG to resume at $dmg" >&2; exit 1; }
    python3 scripts/release_support.py dmg-commit check "$dmg" "$head"
elif [ -e "$dmg" ]; then
    echo 'An unfinished release DMG exists; set MOCHI_RESUME_DMG=1 to continue it, or move it aside to rebuild' >&2
    exit 1
fi
xcrun notarytool history --keychain-profile "$MOCHI_NOTARY_PROFILE" >/dev/null
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
if [ "$resume" != 1 ]; then
    swift test
    python3 -m unittest discover -s scripts/tests
    # A fresh bundle: building over an old one would ship resources that later builds removed.
    rm -rf "$APP" "$OUT/Mochi.zip"
    MOCHI_DISTRIBUTION=1 MOCHI_APP_PATH="$APP" ./scripts/build-app.sh
    python3 scripts/release_support.py metadata "$APP/Contents/Info.plist" "$version" "$build"
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
    ditto -c -k --keepParent "$APP" "$OUT/Mochi.zip"
    python3 scripts/release_support.py notarize "$OUT/Mochi.zip" "$MOCHI_NOTARY_PROFILE"
    staple "$APP"
    codesign --verify --strict --deep "$APP"
    gatekeeper "$APP" -t exec
    staging=$(mktemp -d)
    ditto "$APP" "$staging/Mochi.app"
    ln -s /Applications "$staging/Applications"
    # Nothing may have changed while the app was built; the DMG then records the commit it holds.
    [ "$(python3 scripts/release_support.py source "$version")" = "$head" ] || { echo 'HEAD changed during the build' >&2; exit 1; }
    hdiutil create -quiet -volname "Mochi $version" -srcfolder "$staging" -format UDZO "$dmg"
    python3 scripts/release_support.py dmg-commit record "$dmg" "$head"
    codesign --force --timestamp --sign "$MOCHI_SIGN_ID" "$dmg"
elif ! codesign --verify "$dmg" 2>/dev/null; then
    # Re-signing a signed DMG would change its digest and abandon the saved notary submission.
    codesign --force --timestamp --sign "$MOCHI_SIGN_ID" "$dmg"
fi
python3 scripts/release_support.py notarize "$dmg" "$MOCHI_NOTARY_PROFILE"
staple "$dmg"
gatekeeper "$dmg" -t open --context context:primary-signature
mountpoint=$(mktemp -d)
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mountpoint" "$dmg"
attached=1
codesign --verify --strict --deep "$mountpoint/Mochi.app"
xcrun stapler validate "$mountpoint/Mochi.app"
gatekeeper "$mountpoint/Mochi.app" -t exec
python3 scripts/release_support.py metadata "$mountpoint/Mochi.app/Contents/Info.plist" "$version" "$build"
hdiutil detach -quiet "$mountpoint"
attached=""
rmdir "$mountpoint"
mountpoint=""
# Published checksums name the file only; an absolute path would leak the build machine's home folder.
sums=$(cd "$OUT" && shasum -a 256 "$(basename "$dmg")")
grep -q '/' <<< "$sums" && { echo 'SHA256SUMS must not contain paths' >&2; exit 1; }
python3 scripts/release_support.py cask scripts/distribution/mochi.rb.in "${sums%% *}" "$OUT/mochi.rb" "$version_file"
echo "$sums" > "$OUT/SHA256SUMS"
echo "Release verified: Mochi $version (build $build)"
