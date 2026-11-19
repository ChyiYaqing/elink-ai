#!/bin/sh
set -eu

cd "$(dirname "$0")"

APP="$PWD/.build/ElinkAIBridge.app"
STAGING="$PWD/.build/dmg-root"
VERSION="${RELEASE_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)}"
VERSION="${VERSION#v}"
DMG="$PWD/.build/elink-ai-v$VERSION.dmg"
ZIP="$PWD/.build/elink-ai-v$VERSION.zip"

sh build-app.sh >/dev/null

rm -rf "$STAGING" "$DMG" "$ZIP"
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

# App 内更新用的压缩包：macOS 不允许未授权的 App 读取挂载的 DMG，所以更新不走 DMG。
ditto -c -k --sequesterRsrc --keepParent "$STAGING/Elink AI.app" "$ZIP"

echo "$DMG"
