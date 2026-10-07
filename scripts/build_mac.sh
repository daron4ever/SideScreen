#!/bin/bash
set -e

# Get absolute path to root directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Resolve an explicitly selected identity before stopping the app or cleaning
# outputs. Use the certificate hash for signing so duplicate names cannot select
# a different identity later. Leaving the variable unset preserves ad-hoc builds.
SIGNING_IDENTITY="-"
if [ "${SIDESCREEN_SIGNING_IDENTITY+x}" = "x" ]; then
    if [ -z "$SIDESCREEN_SIGNING_IDENTITY" ]; then
        echo "Error: SIDESCREEN_SIGNING_IDENTITY must not be empty." >&2
        exit 1
    fi
    if ! SIGNING_IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null); then
        echo "Error: Could not check available code-signing identities." >&2
        exit 1
    fi

    REQUESTED_HASH=$(printf '%s' "$SIDESCREEN_SIGNING_IDENTITY" | tr '[:lower:]' '[:upper:]')
    RESOLVED_IDENTITY=""
    IDENTITY_PATTERN='^[[:space:]]*[0-9]+\)[[:space:]]+([[:xdigit:]]{40})'
    IDENTITY_PATTERN+='[[:space:]]+"(.*)"[[:space:]]*$'
    while IFS= read -r identity_line; do
        if [[ "$identity_line" =~ $IDENTITY_PATTERN ]]; then
            identity_name="${BASH_REMATCH[2]}"
            identity_hash=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')
            if [[ "$SIDESCREEN_SIGNING_IDENTITY" == "$identity_name" ||
                  "$REQUESTED_HASH" == "$identity_hash" ]]; then
                if [[ -n "$RESOLVED_IDENTITY" && "$RESOLVED_IDENTITY" != "$identity_hash" ]]; then
                    echo "Error: Signing identity is ambiguous; select its certificate SHA-1." >&2
                    exit 1
                fi
                RESOLVED_IDENTITY="$identity_hash"
            fi
        fi
    done <<< "$SIGNING_IDENTITIES"
    if [ -z "$RESOLVED_IDENTITY" ]; then
        echo "Error: Requested code-signing identity is unavailable or invalid." >&2
        exit 1
    fi
    SIGNING_IDENTITY="$RESOLVED_IDENTITY"
else
    echo "Warning: Ad-hoc signing may require Screen Recording access again after rebuilding." >&2
    echo "Set SIDESCREEN_SIGNING_IDENTITY to a valid code-signing identity for stable signing." >&2
fi

# Read version
VERSION=$(cat "$ROOT_DIR/VERSION" | tr -d '[:space:]')
echo "Building version $VERSION..."

cd "$ROOT_DIR/MacHost"

# Kill running instance
echo "Stopping running Side Screen..."
pkill -f SideScreen 2>/dev/null || true
sleep 0.5

# Clean old build
echo "Cleaning old build..."
rm -rf .build

# Build fresh (Universal Binary: arm64 + x86_64)
echo "Building macOS Host (arm64)..."
swift build -c release --arch arm64

echo "Building macOS Host (x86_64)..."
swift build -c release --arch x86_64

echo "Creating Universal Binary..."
mkdir -p ".build/release-universal"
lipo -create \
  .build/arm64-apple-macosx/release/SideScreen \
  .build/x86_64-apple-macosx/release/SideScreen \
  -output .build/release-universal/SideScreen

# Create .app bundle
APP_NAME="SideScreen"
APP_DIR="$ROOT_DIR/$APP_NAME.app"

echo "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy universal binary
cp .build/release-universal/SideScreen "$APP_DIR/Contents/MacOS/"

# No LaunchAgent plist needed for SMAppService.mainApp

# Copy app icon if exists
if [ -f "$ROOT_DIR/MacHost/Resources/AppIcon.icns" ]; then
    cp "$ROOT_DIR/MacHost/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/"
    echo "  ✓ App icon copied"
fi

# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SideScreen</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.sidescreen.app</string>
    <key>CFBundleName</key>
    <string>Side Screen</string>
    <key>CFBundleDisplayName</key>
    <string>Side Screen</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string><!-- VERSION -->
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string><!-- VERSION -->
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Side Screen needs screen recording access to capture your virtual display and stream it to your Android device.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Side Screen needs Local Network access so your Android tablet can connect to the Mac over WiFi for wireless mode. Without this, only USB-tethered connections work.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_sidescreen._tcp</string>
    </array>
</dict>
</plist>
EOF

# Code sign using the preflighted identity, or the existing ad-hoc default.
if [ "$SIGNING_IDENTITY" = "-" ]; then
    echo "Code signing (ad-hoc)..."
else
    echo "Code signing (configured identity)..."
fi
codesign --force --deep --sign "$SIGNING_IDENTITY" \
    --entitlements "$ROOT_DIR/MacHost/SideScreen.entitlements" "$APP_DIR"
echo "  ✓ App signed"

echo ""
echo "Build successful!"
echo ""
echo "App: $ROOT_DIR/$APP_NAME.app"
echo "To run: open $APP_NAME.app"

# Create DMG with Applications symlink
echo ""
echo "Creating DMG..."
DMG_DIR=$(mktemp -d)
cp -R "$APP_DIR" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"
DMG_PATH="$ROOT_DIR/SideScreen-${VERSION}-mac-universal.dmg"
hdiutil create -volname "Side Screen" -srcfolder "$DMG_DIR" -ov -format UDZO "$DMG_PATH"
rm -rf "$DMG_DIR"
echo "DMG: $DMG_PATH"
