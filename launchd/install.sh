#!/bin/bash
set -euo pipefail

# ============================================================
# Claude Todo — Install All launchd Jobs
# Sets up: session executor, shared dispatcher, Slack poller, caffeinate
# ============================================================

PLIST_DIR="$HOME/Library/LaunchAgents"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_AUTO="$HOME/claude-auto"

echo "╔══════════════════════════════════════════════╗"
echo "║  Claude Todo — launchd Job Installer         ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

mkdir -p "$PLIST_DIR" "$CLAUDE_AUTO/logs"

# === Replace HOME path placeholders in plists ===
# The plists use hardcoded /Users/ayushpuri — replace with current user
CURRENT_HOME="$HOME"
CURRENT_USER=$(whoami)

install_plist() {
  local PLIST_NAME="$1"
  local DESCRIPTION="$2"

  local SRC="$SOURCE_DIR/$PLIST_NAME"
  local DST="$PLIST_DIR/$PLIST_NAME"

  if [ ! -f "$SRC" ]; then
    echo "  ⚠ $PLIST_NAME not found, skipping"
    return
  fi

  # Unload if already loaded
  launchctl unload "$DST" 2>/dev/null || true

  # Copy with HOME path replacement
  sed "s|/Users/ayushpuri|$CURRENT_HOME|g" "$SRC" > "$DST"

  # Load
  launchctl load "$DST" 2>/dev/null

  # Verify
  local LABEL=$(echo "$PLIST_NAME" | sed 's/.plist//')
  if launchctl list | grep -q "$LABEL"; then
    echo "  ✓ $LABEL — $DESCRIPTION"
  else
    echo "  ⚠ $LABEL — loaded but not running"
  fi
}

echo "Installing launchd jobs..."
echo ""

install_plist "com.claude.autorun.plist" \
  "Session executor (fires at 8:30, 13:30, 18:30, 23:30, 4:30)"

install_plist "com.claude.shared-dispatcher.plist" \
  "Shared queue dispatcher (pulls from GitHub every 2 min)"

install_plist "com.claude.slack-poller.plist" \
  "Slack poller (checks @Claude-uat mentions every 3 min)"

install_plist "com.claude.caffeinate.plist" \
  "Sleep prevention (keeps Mac awake)"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  ✓ All launchd jobs installed                ║"
echo "╠══════════════════════════════════════════════╣"
echo "║                                              ║"
echo "║  Verify:  launchctl list | grep claude       ║"
echo "║  Logs:    ~/claude-auto/logs/                ║"
echo "║                                              ║"
echo "╚══════════════════════════════════════════════╝"
