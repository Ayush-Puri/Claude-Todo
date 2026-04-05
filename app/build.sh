#!/bin/bash
set -euo pipefail

APP_NAME="Claude Todo"
BUNDLE_ID="com.claude.todo"
APP_DIR="/Applications/${APP_NAME}.app"
SOURCE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${SOURCE_DIR}/app"
CLAUDE_AUTO_DIR="$HOME/claude-auto"

echo "╔══════════════════════════════════════════╗"
echo "║  Claude Todo — Build & Install           ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# === Step 1: Set up ~/claude-auto directory structure ===
echo "Setting up ~/claude-auto/..."
mkdir -p "$CLAUDE_AUTO_DIR"/{tasks,logs/raw,app}

# Copy source files to ~/claude-auto/ (the app reads dashboard.html from here)
cp "${SOURCE_DIR}/dashboard.html" "$CLAUDE_AUTO_DIR/"
cp "${SOURCE_DIR}/executor.sh" "$CLAUDE_AUTO_DIR/"
cp "${SOURCE_DIR}/runner.sh" "$CLAUDE_AUTO_DIR/"
cp "${SOURCE_DIR}/parse-log.py" "$CLAUDE_AUTO_DIR/"
cp "${SOURCE_DIR}/sync-tasks.sh" "$CLAUDE_AUTO_DIR/"
cp "${SOURCE_DIR}/instructions.md" "$CLAUDE_AUTO_DIR/"
cp "${SOURCE_DIR}/sessions.json" "$CLAUDE_AUTO_DIR/"
cp "${BUILD_DIR}/ClaudeTaskRunner.swift" "$CLAUDE_AUTO_DIR/app/"
cp "${BUILD_DIR}/build.sh" "$CLAUDE_AUTO_DIR/app/"
cp "${BUILD_DIR}/gen_icon.py" "$CLAUDE_AUTO_DIR/app/"

chmod +x "$CLAUDE_AUTO_DIR/executor.sh" "$CLAUDE_AUTO_DIR/runner.sh" "$CLAUDE_AUTO_DIR/parse-log.py" "$CLAUDE_AUTO_DIR/sync-tasks.sh"

echo "  ✓ Files copied to ~/claude-auto/"
echo "  ✓ Created ~/claude-auto/tasks/ (task JSON sync directory)"
echo "  ✓ Created ~/claude-auto/logs/raw/"

# === Step 2: Compile the Swift app ===
echo ""
echo "Compiling ${APP_NAME}..."

swiftc \
  -o "${BUILD_DIR}/ClaudeTaskRunner" \
  -framework Cocoa \
  -framework WebKit \
  -target arm64-apple-macos14.0 \
  -O \
  "${BUILD_DIR}/ClaudeTaskRunner.swift"

echo "  ✓ Binary compiled"

# === Step 3: Create .app bundle ===
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BUILD_DIR}/ClaudeTaskRunner" "${APP_DIR}/Contents/MacOS/ClaudeTaskRunner"

cat > "${APP_DIR}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Claude Todo</string>
  <key>CFBundleDisplayName</key>
  <string>Claude Todo</string>
  <key>CFBundleIdentifier</key>
  <string>com.claude.todo</string>
  <key>CFBundleVersion</key>
  <string>2.0</string>
  <key>CFBundleShortVersionString</key>
  <string>2.0</string>
  <key>CFBundleExecutable</key>
  <string>ClaudeTaskRunner</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticTermination</key>
  <false/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
</dict>
</plist>
PLIST

echo "  ✓ App bundle created"

# === Step 4: Generate app icon ===
echo "Generating icon..."
python3 "${BUILD_DIR}/gen_icon.py" 2>&1 | grep -E "^(All|  Gen)" | head -3

ICONSET_DIR="${BUILD_DIR}/AppIcon.iconset"
if [ -d "$ICONSET_DIR" ]; then
  iconutil -c icns "$ICONSET_DIR" -o "${APP_DIR}/Contents/Resources/AppIcon.icns" 2>/dev/null && \
    echo "  ✓ AppIcon.icns created" || echo "  ⚠ iconutil failed, using default icon"
  rm -rf "$ICONSET_DIR"
fi

# Clean up build artifacts
rm -f "${BUILD_DIR}/ClaudeTaskRunner"

# === Step 5: Install launchd schedules ===
echo ""
echo "Setting up scheduled sessions..."

PLIST_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$PLIST_DIR"

cat > "${PLIST_DIR}/com.claude.autorun.plist" <<LAUNCHD
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.claude.autorun</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${CLAUDE_AUTO_DIR}/executor.sh</string>
  </array>
  <key>StartCalendarInterval</key>
  <array>
    <dict><key>Hour</key><integer>8</integer><key>Minute</key><integer>30</integer></dict>
    <dict><key>Hour</key><integer>13</integer><key>Minute</key><integer>30</integer></dict>
    <dict><key>Hour</key><integer>18</integer><key>Minute</key><integer>30</integer></dict>
    <dict><key>Hour</key><integer>23</integer><key>Minute</key><integer>30</integer></dict>
    <dict><key>Hour</key><integer>4</integer><key>Minute</key><integer>30</integer></dict>
  </array>
  <key>StandardOutPath</key>
  <string>${CLAUDE_AUTO_DIR}/logs/launchd_stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${CLAUDE_AUTO_DIR}/logs/launchd_stderr.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>\${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>HOME</key>
    <string>\${HOME}</string>
  </dict>
</dict>
</plist>
LAUNCHD

# Sleep prevention
cat > "${PLIST_DIR}/com.claude.caffeinate.plist" <<'CAFFPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.claude.caffeinate</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/caffeinate</string>
    <string>-d</string>
    <string>-i</string>
    <string>-s</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
CAFFPLIST

launchctl unload "${PLIST_DIR}/com.claude.autorun.plist" 2>/dev/null || true
launchctl load "${PLIST_DIR}/com.claude.autorun.plist" 2>/dev/null
launchctl unload "${PLIST_DIR}/com.claude.caffeinate.plist" 2>/dev/null || true
launchctl load "${PLIST_DIR}/com.claude.caffeinate.plist" 2>/dev/null

echo "  ✓ Scheduled sessions: 8:30, 13:30, 18:30, 23:30, 4:30"
echo "  ✓ Sleep prevention enabled"

# === Step 6: Register with LaunchServices ===
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${APP_DIR}" 2>/dev/null || true

# === Done ===
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  ✓ Claude Todo installed successfully!   ║"
echo "╠══════════════════════════════════════════╣"
echo "║  App:    /Applications/Claude Todo.app   ║"
echo "║  Data:   ~/claude-auto/                  ║"
echo "║  Tasks:  ~/claude-auto/tasks/            ║"
echo "║  Logs:   ~/claude-auto/logs/             ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "Opening Claude Todo..."
open "${APP_DIR}"
