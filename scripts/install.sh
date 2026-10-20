#!/bin/bash
# Copies the built app to /Applications (or ~/Applications if that is not writable) and starts it.
# Launch at login is then switched on from the app's Settings, or with scripts/install-launchagent.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="build/Claude Usage Monitor.app"
[[ -d "$SRC" ]] || { echo "Build the app first: scripts/build-app.sh" >&2; exit 1; }
DEST_DIR="/Applications"
[[ -w "$DEST_DIR" ]] || { DEST_DIR="$HOME/Applications"; mkdir -p "$DEST_DIR"; }
DEST="$DEST_DIR/Claude Usage Monitor.app"
pkill -x ClaudeUsageMonitor 2>/dev/null || true
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
echo "Installed to $DEST"
open "$DEST"
