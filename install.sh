#!/bin/sh
# Installs tapdrag to ~/.local/bin and runs it at login as a LaunchAgent.
# Grant Accessibility to ~/.local/bin/tapdrag (System Settings > Privacy &
# Security > Accessibility) the first time, then run this again.
set -e
cd "$(dirname "$0")"
[ -x tapdrag ] || ./build.sh
mkdir -p "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp -f tapdrag "$HOME/.local/bin/tapdrag"
PLIST="$HOME/Library/LaunchAgents/local.tapdrag.plist"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.tapdrag</string>
  <key>ProgramArguments</key><array><string>$HOME/.local/bin/tapdrag</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/tapdrag.log</string>
</dict>
</plist>
PL
launchctl bootout "gui/$(id -u)/local.tapdrag" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed; log: ~/Library/Logs/tapdrag.log"
