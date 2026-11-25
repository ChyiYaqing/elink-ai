#!/bin/sh
# Antigravity CLI statusLine helper for elink-ai.
# Atomically caches the state JSON piped on stdin so elink-ai can read
# Gemini 5-hour and weekly quota limits without touching OAuth credentials.
set -eu

CACHE_DIR="${ELINK_STATUSLINE_DIR:-$HOME/.cache/statusline}"
TARGET="$CACHE_DIR/antigravity.json"
TMP="$TARGET.tmp.$$"

mkdir -p "$CACHE_DIR"
cat > "$TMP"
mv -f "$TMP" "$TARGET"
