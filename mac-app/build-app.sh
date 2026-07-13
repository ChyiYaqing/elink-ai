#!/bin/sh
set -eu

cd "$(dirname "$0")"
swift build -c release

APP="$PWD/.build/ElinkAIBridge.app"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
cp .build/release/ElinkAIBridge "$APP/Contents/MacOS/ElinkAIBridge"
chmod 0755 "$APP/Contents/MacOS/ElinkAIBridge"
codesign --force --deep --sign - "$APP"
echo "$APP"
