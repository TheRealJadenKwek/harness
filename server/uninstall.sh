#!/bin/bash
# Stop + remove the Harness background service. Your data (~/.claude-harness) is kept.
set -eu
LABEL="sh.harness.daemon"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
echo "✓ Harness service stopped and removed."
echo "  Your threads/config remain in ~/.claude-harness (delete that folder to remove everything)."
