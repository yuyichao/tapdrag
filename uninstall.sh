#!/bin/sh
launchctl bootout "gui/$(id -u)/local.tapdrag" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/local.tapdrag.plist" "$HOME/.local/bin/tapdrag"
echo "uninstalled"
