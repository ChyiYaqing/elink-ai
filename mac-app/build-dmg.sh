#!/bin/sh
set -eu

cd "$(dirname "$0")"

APP="$PWD/.build/ElinkAIBridge.app"
STAGING="$PWD/.build/dmg-root"
VERSION="${RELEASE_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)}"
VERSION="${VERSION#v}"
DMG="$PWD/.build/elink-ai-v$VERSION.dmg"

sh build-app.sh >/dev/null

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Elink AI.app"
ln -s /Applications "$STAGING/Applications"
xattr -cr "$STAGING"

hdiutil create \
    -volname "Elink AI" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG" >/dev/null

echo "$DMG"
