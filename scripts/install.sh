#!/bin/bash
# Copies the built app to /Applications (or ~/Applications if that is not writable) and starts it.
# Launch at login is then switched on from the app's Settings, or with scripts/install-launchagent.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="build/AI Usage Monitor.app"
[[ -d "$SRC" ]] || { echo "Build the app first: scripts/build-app.sh" >&2; exit 1; }
DEST_DIR="/Applications"
[[ -w "$DEST_DIR" ]] || { DEST_DIR="$HOME/Applications"; mkdir -p "$DEST_DIR"; }
DEST="$DEST_DIR/AI Usage Monitor.app"
pkill -x ClaudeUsageMonitor 2>/dev/null || true
# The app was called "Claude Usage Monitor" before it supported several providers. Remove the old copy so that
# only one app is listed.
rm -rf "$DEST_DIR/Claude Usage Monitor.app"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
echo "Installed to $DEST"
open "$DEST"
