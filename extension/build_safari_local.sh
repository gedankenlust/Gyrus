#!/bin/sh
# Build an unsigned Safari wrapper for this Mac. No Apple Developer account.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${HOME}/Builds/Gyrus/Safari"
APP_NAME="GyrusSaver"
APP_ID="local.gyrus.saver"
EXT_ID="${APP_ID}.Extension"
rm -rf "$DEST"
mkdir -p "$DEST"
xcrun safari-web-extension-converter "$ROOT/extension" \
  --project-location "$DEST" \
  --app-name "$APP_NAME" \
  --bundle-identifier "$APP_ID" \
  --swift \
  --macos-only \
  --no-open \
  --no-prompt \
  --force
# The converter may still name targets after the app name (local.gyrus.GyrusSaver).
# Safari hides the extension unless its bundle id starts with the app id + ".".
PBXPROJ="$DEST/$APP_NAME/$APP_NAME.xcodeproj/project.pbxproj"
perl -i -pe '
  if (/PRODUCT_BUNDLE_IDENTIFIER = .*Extension;/) {
    s/PRODUCT_BUNDLE_IDENTIFIER = [^;]+;/PRODUCT_BUNDLE_IDENTIFIER = '"$EXT_ID"';/;
  } elsif (/PRODUCT_BUNDLE_IDENTIFIER = /) {
    s/PRODUCT_BUNDLE_IDENTIFIER = [^;]+;/PRODUCT_BUNDLE_IDENTIFIER = '"$APP_ID"';/;
  }
' "$PBXPROJ"
# Safari shows the wrapping app's icon. The converter leaves that slot empty,
# so the Extensions pane shows a blank tile until we fill it.
ICON_SRC="$ROOT/docs/icon.png"
APPICON="$DEST/$APP_NAME/$APP_NAME/Assets.xcassets/AppIcon.appiconset"
while IFS=' ' read -r name pixels; do
  sips -z "$pixels" "$pixels" "$ICON_SRC" --out "$APPICON/$name" >/dev/null
done <<'EOF'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
EOF
cat > "$APPICON/Contents.json" <<'EOF'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF
# Ad-hoc signing drops the sandbox entitlements Xcode would inject under Automatic
# signing. Safari will not list the extension without them.
APP_ENT="$DEST/$APP_NAME/$APP_NAME/$APP_NAME.entitlements"
EXT_ENT="$DEST/$APP_NAME/$APP_NAME Extension/$APP_NAME Extension.entitlements"
cat > "$APP_ENT" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-only</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
</plist>
EOF
cat > "$EXT_ENT" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
</plist>
EOF
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
APPEX="$APP/Contents/PlugIns/$APP_NAME Extension.appex"
codesign --force --sign - --entitlements "$EXT_ENT" "$APPEX"
codesign --force --sign - --entitlements "$APP_ENT" "$APP"
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
osascript -e 'quit app "Safari"' 2>/dev/null || true
sleep 1
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP" "/Applications/$APP_NAME.app"
echo "Installed /Applications/$APP_NAME.app"
echo "App id: $APP_ID"
echo "Extension id: $EXT_ID"
echo "In Safari: Settings → Advanced → show web developer features, then Develop → Allow Unsigned Extensions."
echo "Open /Applications/$APP_NAME.app once and enable the extension."
