#!/bin/bash
# Alternative to the in-app "Launch at login" switch: installs a per-user LaunchAgent that starts the
# app at login and restarts it if it ever crashes.   Remove with: scripts/install-launchagent.sh --remove
set -euo pipefail
LABEL="dev.tokenwatch.app.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
if [[ "${1:-}" == "--remove" ]]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Removed $LABEL"
    exit 0
fi
APP="/Applications/Tokenwatch.app"
[[ -d "$APP" ]] || APP="$HOME/Applications/Tokenwatch.app"
[[ -d "$APP" ]] || { echo "Install the app first: scripts/install.sh" >&2; exit 1; }
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/Tokenwatch</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Background</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed LaunchAgent $LABEL (starts at login, restarts after a crash)"
