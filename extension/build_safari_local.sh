#!/bin/sh
# Build an unsigned Safari wrapper for this Mac. No Apple Developer account.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${HOME}/Builds/Gyrus/Safari"
APP_NAME="GyrusSaver"
rm -rf "$DEST"
mkdir -p "$DEST"
xcrun safari-web-extension-converter "$ROOT/extension" \
  --project-location "$DEST" \
  --app-name "$APP_NAME" \
  --bundle-identifier "local.gyrus.saver" \
  --swift \
  --macos-only \
  --no-open \
  --no-prompt \
  --force
# The converter names the app id after the app name. The extension id must
# start with that app id, so both stay on local.gyrus.saver.
sed -i '' 's/PRODUCT_BUNDLE_IDENTIFIER = local.gyrus.GyrusSaver;/PRODUCT_BUNDLE_IDENTIFIER = local.gyrus.saver;/g' \
  "$DEST/$APP_NAME/$APP_NAME.xcodeproj/project.pbxproj"
xcodebuild \
  -project "$DEST/$APP_NAME/$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$DEST/DerivedData" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" \
  build
APP="$DEST/DerivedData/Build/Products/Release/$APP_NAME.app"
codesign --force --deep --sign - "$APP"
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP" "/Applications/$APP_NAME.app"
echo "Installed /Applications/$APP_NAME.app"
echo "In Safari: Settings → Advanced → show web developer features, then Develop → Allow Unsigned Extensions."
echo "Open /Applications/$APP_NAME.app once and enable the extension."
