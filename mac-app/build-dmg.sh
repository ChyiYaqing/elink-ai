#!/bin/sh
set -eu

cd "$(dirname "$0")"

APP="$PWD/.build/ElinkAIBridge.app"
STAGING="$PWD/.build/dmg-root"
VERSION="${RELEASE_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)}"
VERSION="${VERSION#v}"
DMG="$PWD/.build/elink-ai-v$VERSION.dmg"
HYBRID="$PWD/.build/elink-ai-v$VERSION.hybrid.dmg"

sh build-app.sh >/dev/null

rm -rf "$STAGING" "$DMG" "$HYBRID"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Elink AI.app"
ln -s /Applications "$STAGING/Applications"

hdiutil makehybrid \
    -hfs \
    -hfs-volume-name "Elink AI" \
    -ov \
    -o "$HYBRID" \
    "$STAGING" >/dev/null
hdiutil convert "$HYBRID" -format UDZO -o "$DMG" >/dev/null
rm -f "$HYBRID"

echo "$DMG"
