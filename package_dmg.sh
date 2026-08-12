#!/usr/bin/env bash
#
# Create a DMG installer for Gyrus.
# Uses 'create-dmg' (brew install create-dmg) when Finder can be scripted, and
# falls back to plain hdiutil otherwise. See "Packaging modes" below.
set -euo pipefail

# 1. Setup paths
APP_NAME="Gyrus"
BUILD_ROOT="${GYRUS_BUILD_ROOT:-$HOME/Builds/Gyrus}"
APP_PATH="${GYRUS_APP_PATH:-$BUILD_ROOT/DerivedData/Build/Products/Release/${APP_NAME}.app}"
ARTIFACT_DIR="${GYRUS_ARTIFACT_DIR:-$BUILD_ROOT/artifacts}"
DMG_PATH="$ARTIFACT_DIR/${APP_NAME}.dmg"
VOL_NAME="${APP_NAME} Installer"
mkdir -p "$ARTIFACT_DIR"

# 2. Check if the app exists
if [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: ${APP_PATH} not found. Please build the app in Release mode first."
    exit 1
fi

# 3. Clean up output from earlier runs. Leftover rw.*.dmg scratch images would
# otherwise be picked up as release artifacts and confuse the checksum step.
rm -f "$DMG_PATH"
rm -f "$ARTIFACT_DIR"/rw.*."${APP_NAME}".dmg 2>/dev/null || true

echo "🔨 Creating DMG for ${APP_NAME}..."

# 4. Stage the app in its own folder.
#
# create-dmg hands its source argument straight to hdiutil, which copies the
# *contents* of that folder into the image. Passing Gyrus.app directly would
# therefore put Contents/ at the top level with no draggable app at all. Give it
# a folder that contains Gyrus.app instead.
STAGING=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/gyrus-dmg.XXXXXXXX")
trap 'rm -rf "$STAGING"' EXIT
# ditto, not cp: it preserves the extended attributes carrying the code signature.
/usr/bin/ditto "$APP_PATH" "$STAGING/${APP_NAME}.app"

# An interrupted run can leave create-dmg's scratch volume mounted, which makes
# the next attempt fail on "Resource busy". Only touch the temporary dmg.* mounts
# create-dmg itself creates, plus our own volume name — never anything else the
# user happens to have mounted.
detach_stale_mounts() {
    for STALE in /Volumes/dmg.* "/Volumes/${VOL_NAME}"; do
        [ -d "$STALE" ] && /usr/bin/hdiutil detach "$STALE" -force -quiet 2>/dev/null || true
    done
}

# 5. Packaging modes.
#
# Preferred: create-dmg, which arranges the installer window (icon positions,
# window size) through Finder. That styling is written by an AppleScript, so it
# needs Automation → Finder permission for whichever process runs this script. A
# normal Terminal usually has it; CI and sandboxed agents do not.
#
# Fallback: plain `hdiutil create -srcfolder`, which produces the same app plus
# /Applications symlink and loses only the window cosmetics.
#
# Note create-dmg's own --sandbox-safe flag is deliberately NOT used here. It
# switches to `hdiutil makehybrid -hfs`, which attaches com.apple.FinderInfo to
# every file; codesign then rejects the bundle with "resource fork, Finder
# information, or similar detritus not allowed". That silently ships an app whose
# signature no longer verifies, which is worse than losing the icon layout.
create_dmg_styled() {
    create-dmg \
      --volname "${VOL_NAME}" \
      --window-pos 200 120 \
      --window-size 600 400 \
      --icon-size 100 \
      --icon "${APP_NAME}.app" 150 180 \
      --hide-extension "${APP_NAME}.app" \
      --app-drop-link 450 180 \
      "${DMG_PATH}" \
      "${STAGING}"
}

create_dmg_plain() {
    ln -sf /Applications "$STAGING/Applications"
    /usr/bin/hdiutil create \
      -srcfolder "$STAGING" \
      -volname "${VOL_NAME}" \
      -fs HFS+ \
      -format UDZO \
      -quiet \
      "${DMG_PATH}"
}

# The probe has to ask for a real Finder object. `get name of application
# "Finder"` is answered even without Automation consent, so it would report
# success and send us down the styled path anyway; touching a window or a disk is
# what actually raises -1743, and it is what the template script does.
if /usr/bin/osascript -e 'tell application "Finder" to return count of windows' >/dev/null 2>&1; then
    STYLED=1
else
    STYLED=0
    echo "⚠️  Finder cannot be scripted from here (Automation permission missing),"
    echo "   so the installer window will not be pre-arranged."
fi

detach_stale_mounts

STATUS=0
if [ "$STYLED" -eq 1 ]; then
    # `|| STATUS=$?` rather than `if ! …`: under `set -e` the latter would report
    # the negated status and hide the real one. create-dmg's status after a
    # rejected Apple event is not dependable either — it tries to detach its
    # scratch image first and can die with hdiutil's 16 before its own exit 64 —
    # so treat any non-zero status as "fall back".
    create_dmg_styled || STATUS=$?
    if [ "$STATUS" -ne 0 ]; then
        echo "⚠️  Styled packaging failed (status ${STATUS}); falling back to plain hdiutil…"
        STYLED=0
    fi
fi
if [ "$STYLED" -eq 0 ]; then
    rm -f "$DMG_PATH"
    rm -f "$ARTIFACT_DIR"/rw.*."${APP_NAME}".dmg 2>/dev/null || true
    detach_stale_mounts
    create_dmg_plain
fi

# 6. Verify what actually ends up in the image.
#
# Worth the extra mount: a packaging change once produced a DMG holding a bare
# Contents/ folder instead of Gyrus.app, and another produced one whose signature
# no longer verified. Both still build and still checksum. Never ship unverified.
MOUNT_POINT=$(/usr/bin/hdiutil attach -nobrowse -readonly -plist "$DMG_PATH" \
    | /usr/bin/grep -A1 "mount-point" | /usr/bin/grep string \
    | /usr/bin/sed -E 's:.*<string>(.*)</string>.*:\1:')
if [ -z "$MOUNT_POINT" ]; then
    echo "❌ Could not mount ${DMG_PATH} to verify its contents."
    exit 1
fi
DMG_APP="$MOUNT_POINT/${APP_NAME}.app"
[ -d "$DMG_APP" ] && APP_OK="yes" || APP_OK="no"
[ -L "$MOUNT_POINT/Applications" ] && LINK_OK="yes" || LINK_OK="no"
SIG_OK="skipped"
DMG_VER="unknown"
DMG_MIN="unknown"
if [ "$APP_OK" = "yes" ]; then
    SIG_DETAIL=$(codesign --verify --deep --strict "$DMG_APP" 2>&1) && SIG_OK="yes" || SIG_OK="no"
    DMG_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
        "$DMG_APP/Contents/Info.plist" 2>/dev/null || echo "unset")
    DMG_MIN=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" \
        "$DMG_APP/Contents/Info.plist" 2>/dev/null || echo "unset")
fi
/usr/bin/hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null \
    || /usr/bin/hdiutil detach "$MOUNT_POINT" -force -quiet 2>/dev/null || true

if [ "$APP_OK" != "yes" ] || [ "$LINK_OK" != "yes" ] || [ "$SIG_OK" != "yes" ]; then
    echo "❌ DMG verification failed:"
    echo "   ${APP_NAME}.app present: ${APP_OK}"
    echo "   /Applications link:      ${LINK_OK}"
    echo "   signature valid:         ${SIG_OK}"
    [ "${SIG_DETAIL:-}" ] && echo "   ${SIG_DETAIL}" | head -3
    exit 1
fi

if [ "$STYLED" -eq 1 ]; then
    echo "✅ DMG created: ${DMG_PATH}"
else
    echo "✅ DMG created (no window layout): ${DMG_PATH}"
    echo "   For the arranged installer window, run this from a Terminal that has"
    echo "   Automation → Finder access (System Settings → Privacy & Security)."
fi
echo "✓ Verified: ${APP_NAME}.app ${DMG_VER} (min macOS ${DMG_MIN}), signature valid, /Applications link present"
