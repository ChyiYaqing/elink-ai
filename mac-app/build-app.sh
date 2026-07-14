#!/bin/sh
set -eu

cd "$(dirname "$0")"
swift build -c release

APP="$PWD/.build/ElinkAIBridge.app"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp .build/release/ElinkAIBridge "$APP/Contents/MacOS/ElinkAIBridge"
cp Resources/ElinkAIBridge.icns "$APP/Contents/Resources/ElinkAIBridge.icns"
cp Resources/elink-ai-menubar.png "$APP/Contents/Resources/elink-ai-menubar.png"
chmod 0755 "$APP/Contents/MacOS/ElinkAIBridge"
codesign --force --deep --sign - "$APP"
echo "$APP"
