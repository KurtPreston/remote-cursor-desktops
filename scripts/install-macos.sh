#!/usr/bin/env bash
# Install wsm-macos (wsmd) as a launchd LaunchAgent that runs at login.
#
# Builds the Go binary, drops a config from the example if none exists, and
# registers ~/Library/LaunchAgents/com.wsm.wsmd.plist (RunAtLoad + KeepAlive).
#
# Requires: Go 1.22+, and the `cursor` CLI (or Cursor.app) for opening windows.
# The process running osascript needs macOS Accessibility permission.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${WSM_BIN_DIR:-$HOME/.local/bin}"
BIN="$BIN_DIR/wsm-macos"
CONFIG_DIR="$HOME/.config/wsm"
CONFIG="$CONFIG_DIR/config.jsonc"
PLIST="$HOME/Library/LaunchAgents/com.wsm.wsmd.plist"
LABEL="com.wsm.wsmd"

echo "==> Building wsm-macos"
mkdir -p "$BIN_DIR"
( cd "$REPO_ROOT" && go build -o "$BIN" ./apps/wsm-macos )

if [[ ! -f "$CONFIG" ]]; then
  echo "==> Writing example config to $CONFIG (edit it to set a token!)"
  mkdir -p "$CONFIG_DIR"
  cp "$REPO_ROOT/config/wsm.config.example.jsonc" "$CONFIG"
fi

echo "==> Writing LaunchAgent $PLIST"
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${BIN}</string>
    <string>-config</string>
    <string>${CONFIG}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/tmp/wsmd.log</string>
  <key>StandardOutPath</key><string>/tmp/wsmd.log</string>
</dict>
</plist>
PLIST_EOF

echo "==> (Re)loading the LaunchAgent"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "==> Done. Health check:"
echo "    curl http://127.0.0.1:39788/health   # -> ok"
echo "    Logs: /tmp/wsmd.log"
