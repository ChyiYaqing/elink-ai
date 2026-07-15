#!/bin/sh
set -eu

cd "$(dirname "$0")"

if [ -n "${ELINK_BINARY:-}" ]; then
    BINARY="$ELINK_BINARY"
else
    swift build -c release
    BINARY="$PWD/.build/release/ElinkAIBridge"
fi

if [ ! -f "$BINARY" ]; then
    echo "ElinkAIBridge binary not found: $BINARY" >&2
    exit 1
fi

APP="$PWD/.build/ElinkAIBridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp "$BINARY" "$APP/Contents/MacOS/ElinkAIBridge"
cp Resources/ElinkAIBridge.icns "$APP/Contents/Resources/ElinkAIBridge.icns"
cp Resources/elink-ai-menubar.png "$APP/Contents/Resources/elink-ai-menubar.png"
chmod 0755 "$APP/Contents/MacOS/ElinkAIBridge"
codesign --force --deep --sign - "$APP"
echo "$APP"
