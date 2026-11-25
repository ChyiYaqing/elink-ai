#!/bin/sh
# Antigravity CLI statusLine helper for elink-ai.
# Atomically caches the state JSON piped on stdin so elink-ai can read
# Gemini 5-hour and weekly quota limits without touching OAuth credentials.
# The Mac app only reads ~/.cache/statusline; the TUI reads the directory of its
# [paths].statusline_cache, so ELINK_STATUSLINE_DIR must match that when set.
set -eu

CACHE_DIR="${ELINK_STATUSLINE_DIR:-$HOME/.cache/statusline}"
TARGET="$CACHE_DIR/antigravity.json"

mkdir -p "$CACHE_DIR"
# mktemp creates the file exclusively, so a planted symlink is never followed.
TMP=$(mktemp "$TARGET.XXXXXX")
cat > "$TMP"
# A statusLine command's stdout is the status line; print the model name so it
# is not left blank. Read it from this call's input: another session may
# replace the shared target right after the rename.
MODEL=$(sed -n 's/.*"display_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TMP" | head -n 1)
mv -f "$TMP" "$TARGET"
printf '%s\n' "$MODEL"
