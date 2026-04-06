#!/bin/bash
set -euo pipefail

# ============================================================
# Claude Todo — Uninstall All launchd Jobs
# ============================================================

PLIST_DIR="$HOME/Library/LaunchAgents"

echo "Unloading Claude Todo launchd jobs..."

for PLIST in com.claude.autorun com.claude.shared-dispatcher com.claude.slack-poller com.claude.caffeinate; do
  if launchctl list | grep -q "$PLIST"; then
    launchctl unload "$PLIST_DIR/$PLIST.plist" 2>/dev/null && echo "  ✓ Unloaded $PLIST" || echo "  ⚠ Failed to unload $PLIST"
  else
    echo "  - $PLIST (not loaded)"
  fi
done

echo ""
echo "All jobs unloaded. Plist files remain in $PLIST_DIR — delete manually if needed."
