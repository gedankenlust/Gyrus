#!/usr/bin/env bash
#
# Create a professional DMG installer for Gyrus.
# Requires 'create-dmg' (brew install create-dmg).

# 1. Setup paths
APP_NAME="Gyrus"
APP_PATH="build/Build/Products/Release/${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"
VOL_NAME="${APP_NAME} Installer"

# 2. Check if the app exists
if [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: ${APP_PATH} not found. Please build the app in Release mode first."
    exit 1
fi

# 3. Clean up old DMG
if [ -f "$DMG_NAME" ]; then
    rm "$DMG_NAME"
fi

echo "🔨 Creating DMG for ${APP_NAME}..."

# 4. Create DMG
# This command sets up the icons, the background, and the /Applications link.
create-dmg \
  --volname "${VOL_NAME}" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "${APP_NAME}.app" 150 180 \
  --hide-extension "${APP_NAME}.app" \
  --app-drop-link 450 180 \
  "${DMG_NAME}" \
  "${APP_PATH}"

echo "✅ DMG created: ${DMG_NAME}"
