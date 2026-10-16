#!/bin/bash
# Builds Agent Monitor as a menu bar app, installs it to ~/Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/AgentMonitor"
APP="$HOME/Applications/Agent Monitor.app"

pkill -x AgentMonitor 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/AgentMonitor"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

open "$APP"
echo "Terpasang dan dijalankan: $APP"
