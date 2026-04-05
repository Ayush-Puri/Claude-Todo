#!/bin/bash
set -euo pipefail

APP_NAME="Claude Task Runner"
BUNDLE_ID="com.claude.taskrunner"
APP_DIR="$HOME/Applications/${APP_NAME}.app"
BUILD_DIR="$HOME/claude-auto/app"

echo "Building ${APP_NAME}..."

# Compile the Swift source
swiftc \
  -o "${BUILD_DIR}/ClaudeTaskRunner" \
  -framework Cocoa \
  -framework WebKit \
  -target arm64-apple-macos14.0 \
  -O \
  "${BUILD_DIR}/ClaudeTaskRunner.swift"

echo "Compiled binary."

# Create .app bundle structure
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

# Copy binary
cp "${BUILD_DIR}/ClaudeTaskRunner" "${APP_DIR}/Contents/MacOS/ClaudeTaskRunner"

# Create Info.plist
cat > "${APP_DIR}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Claude Task Runner</string>
  <key>CFBundleDisplayName</key>
  <string>Claude Task Runner</string>
  <key>CFBundleIdentifier</key>
  <string>com.claude.taskrunner</string>
  <key>CFBundleVersion</key>
  <string>1.0</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
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

# Generate app icon (purple/gradient octagon)
python3 - <<'PYICON'
import struct, zlib, os

def create_png(width, height, pixels):
    """Create a minimal PNG from RGBA pixel data."""
    def chunk(chunk_type, data):
        c = chunk_type + data
        crc = struct.pack('>I', zlib.crc32(c) & 0xffffffff)
        return struct.pack('>I', len(data)) + c + crc

    header = b'\x89PNG\r\n\x1a\n'
    ihdr = chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))

    raw = b''
    for y in range(height):
        raw += b'\x00'  # filter none
        for x in range(width):
            idx = (y * width + x) * 4
            raw += bytes(pixels[idx:idx+4])

    idat = chunk(b'IDAT', zlib.compress(raw, 9))
    iend = chunk(b'IEND', b'')
    return header + ihdr + idat + iend

def make_icon(size):
    pixels = [0] * (size * size * 4)
    cx, cy = size / 2, size / 2
    r = size * 0.42

    for y in range(size):
        for x in range(size):
            dx, dy = x - cx, y - cy
            dist = (dx*dx + dy*dy) ** 0.5
            idx = (y * size + x) * 4

            if dist < r:
                # Gradient: purple to pink
                t = y / size
                red = int(124 + (244 - 124) * t)
                green = int(106 + (114 - 106) * t)
                blue = int(255 + (182 - 255) * t)

                # Inner circle detail - lightning bolt zone
                inner = dist / r
                if inner < 0.55:
                    # Brighter center
                    bright = 1 + (0.55 - inner) * 0.6
                    red = min(255, int(red * bright))
                    green = min(255, int(green * bright))
                    blue = min(255, int(blue * bright))

                # Anti-alias edge
                edge = max(0, min(1, (r - dist) * 2))
                alpha = int(255 * edge)

                pixels[idx] = red
                pixels[idx+1] = green
                pixels[idx+2] = blue
                pixels[idx+3] = alpha
            else:
                pixels[idx:idx+4] = [0, 0, 0, 0]

    return create_png(size, size, pixels)

# Create iconset
iconset_dir = os.path.expanduser('~/claude-auto/app/AppIcon.iconset')
os.makedirs(iconset_dir, exist_ok=True)

icon_sizes = [
    (16, 1), (16, 2), (32, 1), (32, 2),
    (128, 1), (128, 2), (256, 1), (256, 2),
    (512, 1), (512, 2)
]

for base, scale in icon_sizes:
    actual = base * scale
    png = make_icon(actual)
    suffix = f'_{base}x{base}{"@2x" if scale == 2 else ""}.png'
    path = os.path.join(iconset_dir, f'icon{suffix}')
    with open(path, 'wb') as f:
        f.write(png)
    print(f'  Generated {path} ({actual}x{actual})')

print('Icon PNGs generated.')
PYICON

# Convert iconset to icns
iconutil -c icns "${BUILD_DIR}/AppIcon.iconset" -o "${APP_DIR}/Contents/Resources/AppIcon.icns" 2>/dev/null && \
  echo "Created AppIcon.icns" || \
  echo "Warning: iconutil failed, app will use default icon"

# Clean up
rm -rf "${BUILD_DIR}/AppIcon.iconset"
rm -f "${BUILD_DIR}/ClaudeTaskRunner"

echo ""
echo "=== Built successfully! ==="
echo "App location: ${APP_DIR}"
echo ""
echo "Opening app..."
open "${APP_DIR}"
