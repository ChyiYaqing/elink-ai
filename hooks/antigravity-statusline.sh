#!/bin/sh
# Antigravity CLI statusLine helper for elink-ai.
# Atomically caches the state JSON piped on stdin so elink-ai can read
# Gemini 5-hour and weekly quota limits without touching OAuth credentials.
# The path is fixed: the Mac app and the TUI both read ~/.cache/statusline.
set -eu

CACHE_DIR="$HOME/.cache/statusline"
TARGET="$CACHE_DIR/antigravity.json"
TMP="$TARGET.tmp.$$"

mkdir -p "$CACHE_DIR"
cat > "$TMP"
mv -f "$TMP" "$TARGET"

# A statusLine command's stdout is the status line; print the model name so it
# is not left blank.
sed -n 's/.*"display_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TARGET" | head -n 1
