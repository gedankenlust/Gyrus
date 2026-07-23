#!/usr/bin/env bash
#
# Gyrus release script — bumps every version location, builds, packages, tags.
#
#   ./release.sh 1.4.0-beta.1            # bump + build + artifacts
#   ./release.sh 1.4.0-beta.1 --publish  # …plus commit, tag, push, prerelease
#
# macOS and Chrome require a numeric app version. A prerelease therefore uses
# 1.4.0 inside the app and extension, while Git/GitHub use v1.4.0-beta.1.
#
# Version locations kept in sync:
#   - Gyrus.xcodeproj/project.pbxproj  MARKETING_VERSION (2×) + CURRENT_PROJECT_VERSION (2×)
#   - extension/manifest.json          "version"
#   - Gyrus/Resources/Info.plist       release channel
#   - Gyrus/Views/Settings/SettingsView.swift  About-pane fallback string
#   - generate_xcodeproj.py            generated-project version and build
#   - backend/main.py                  API/health version
#   - README.md                        badge and extension archive name
#   - CHANGELOG.md                     must already contain a matching section
set -euo pipefail
cd "$(dirname "$0")"

RELEASE_VERSION="${1:-}"
PUBLISH="${2:-}"
if [[ -n "$PUBLISH" && "$PUBLISH" != "--publish" ]]; then
    echo "Unknown option: $PUBLISH"
    echo "Usage: ./release.sh <version> [--publish]"
    exit 1
fi
if [[ "$RELEASE_VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(-(beta|rc)\.[0-9]+)?$ ]]; then
    APP_VERSION="${BASH_REMATCH[1]}"
    RELEASE_CHANNEL="${BASH_REMATCH[2]#-}"
else
    echo "Usage: ./release.sh <version> [--publish]"
    echo "Examples: ./release.sh 1.4.0-beta.1  |  ./release.sh 1.4.0"
    exit 1
fi
TAG="v$RELEASE_VERSION"
BUILD_ROOT="${GYRUS_BUILD_ROOT:-$HOME/Builds/Gyrus}"
DERIVED_DATA_PATH="${GYRUS_DERIVED_DATA_PATH:-$BUILD_ROOT/DerivedData}"
ARTIFACT_DIR="${GYRUS_ARTIFACT_DIR:-$BUILD_ROOT/releases/$TAG}"

PBXPROJ="Gyrus.xcodeproj/project.pbxproj"
MANIFEST="extension/manifest.json"
INFO_PLIST="Gyrus/Resources/Info.plist"
SETTINGS="Gyrus/Views/Settings/SettingsView.swift"
GENERATOR="generate_xcodeproj.py"
BACKEND_MAIN="backend/main.py"
README="README.md"

# --- Preflight -------------------------------------------------------------
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "❌ Tag $TAG already exists."; exit 1
fi
if ! grep -q "## \[$RELEASE_VERSION\]" CHANGELOG.md; then
    echo "❌ CHANGELOG.md has no '## [$RELEASE_VERSION]' section. Write the changelog first."; exit 1
fi
if [[ "$PUBLISH" == "--publish" ]]; then
    if [[ "$(git branch --show-current)" != "main" ]]; then
        echo "❌ Releases may only be published from main."; exit 1
    fi
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "❌ Working tree not clean — commit or stash before publishing."; exit 1
    fi
fi

OLD_VERSION=$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' "$PBXPROJ" | head -1)
OLD_BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \(.*\);/\1/p' "$PBXPROJ" | head -1)
NEW_BUILD=$((OLD_BUILD + 1))
echo "▶ $OLD_VERSION (build $OLD_BUILD) → $APP_VERSION ${RELEASE_CHANNEL:-stable} (build $NEW_BUILD)"
echo "▶ Build output: $BUILD_ROOT"

# --- Bump every version location -------------------------------------------
sed -i '' "s/MARKETING_VERSION = $OLD_VERSION;/MARKETING_VERSION = $APP_VERSION;/g" "$PBXPROJ"
sed -i '' "s/CURRENT_PROJECT_VERSION = $OLD_BUILD;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" "$PBXPROJ"
python3 - "$MANIFEST" "$APP_VERSION" "$RELEASE_CHANNEL" <<'PY'
import json
import sys

path, app_version, channel = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)
manifest["version"] = app_version
if channel:
    manifest["version_name"] = f"{app_version} {channel.replace('.', ' ')}"
else:
    manifest.pop("version_name", None)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, ensure_ascii=True, indent=2)
    handle.write("\n")
PY
if [[ -n "$RELEASE_CHANNEL" ]]; then
    if /usr/libexec/PlistBuddy -c "Print :GyrusReleaseChannel" "$INFO_PLIST" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :GyrusReleaseChannel $RELEASE_CHANNEL" "$INFO_PLIST"
    else
        /usr/libexec/PlistBuddy -c "Add :GyrusReleaseChannel string $RELEASE_CHANNEL" "$INFO_PLIST"
    fi
else
    /usr/libexec/PlistBuddy -c "Delete :GyrusReleaseChannel" "$INFO_PLIST" >/dev/null 2>&1 || true
fi
# Only the marketing-version fallback line — the About pane also has a
# CFBundleVersion fallback ('?? "1"') that must not become "1.3.0".
sed -i '' "/CFBundleShortVersionString/s/?? \"[0-9.]*\"/?? \"$APP_VERSION\"/" "$SETTINGS"
sed -i '' -E "s/^MARKETING_VERSION = \"[0-9.]+\"/MARKETING_VERSION = \"$APP_VERSION\"/" "$GENERATOR"
sed -i '' -E "s/^BUILD_VERSION = \"[0-9]+\"/BUILD_VERSION = \"$NEW_BUILD\"/" "$GENERATOR"
sed -i '' -E "s/^APP_VERSION = \"[^\"]+\"/APP_VERSION = \"$RELEASE_VERSION\"/" "$BACKEND_MAIN"
BADGE_VERSION="${RELEASE_VERSION/-/--}"
sed -i '' -E "s/version-[0-9]+\.[0-9]+\.[0-9]+(--(beta|rc)\.[0-9]+)?-f59e0b/version-$BADGE_VERSION-f59e0b/" "$README"
sed -i '' -E "s/Gyrus-Saver-v[0-9]+\.[0-9]+\.[0-9]+(-(beta|rc)\.[0-9]+)?\.zip/Gyrus-Saver-v$RELEASE_VERSION.zip/g" "$README"
sed -i '' -E "s#/releases/tag/v[0-9]+\.[0-9]+\.[0-9]+(-(beta|rc)\.[0-9]+)?#/releases/tag/$TAG#g" "$README"
sed -i '' -E "s/Current preview: v[0-9]+\.[0-9]+\.[0-9]+(-(beta|rc)\.[0-9]+)?/Current preview: $TAG/" "$README"

# Verify nothing was missed
for f in "$PBXPROJ" "$MANIFEST" "$SETTINGS" "$GENERATOR"; do
    if ! grep -q "$APP_VERSION" "$f"; then echo "❌ App-version bump failed in $f"; exit 1; fi
done
grep -q "$RELEASE_VERSION" "$BACKEND_MAIN" || { echo "❌ Release-version bump failed in $BACKEND_MAIN"; exit 1; }
grep -q "$RELEASE_VERSION" "$README" || { echo "❌ Release-version bump failed in $README"; exit 1; }
echo "✓ App, backend, extension, generator, and README versions synchronized"

# --- Build + package --------------------------------------------------------
echo "▶ Security and regression tests…"
backend/venv/bin/python -m pytest -q backend/tests
xcodebuild test -project Gyrus.xcodeproj -scheme Gyrus \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

echo "▶ Release build…"
rm -rf "$DERIVED_DATA_PATH/Build/Products/Release/Gyrus.app"
xcodebuild -scheme Gyrus -configuration Release -derivedDataPath "$DERIVED_DATA_PATH" \
    -destination 'platform=macOS' build

APP="$DERIVED_DATA_PATH/Build/Products/Release/Gyrus.app"
BUILT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
if [[ "$BUILT" != "$APP_VERSION" ]]; then
    echo "❌ Built bundle reports $BUILT, expected $APP_VERSION"; exit 1
fi
echo "✓ Built Gyrus.app $BUILT (build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"))"
# Seal bundled third-party executables without forcing Gyrus's hardened-runtime
# options onto Chromium/Python, then harden the actual app executable.
codesign --force --deep --sign - "$APP"
codesign --force --sign - --options runtime "$APP"
codesign --verify --deep --strict "$APP"
echo "✓ Hardened ad-hoc signature and sealed resources verified"

PY="$APP/Contents/Resources/backend/python-runtime/bin/python3"
BROWSERS="$APP/Contents/Resources/backend/python-runtime/playwright-browsers"
PYTHONDONTWRITEBYTECODE=1 PLAYWRIGHT_BROWSERS_PATH="$BROWSERS" "$PY" -c \
    "from playwright.sync_api import sync_playwright; p=sync_playwright().start(); b=p.chromium.launch(headless=True); print('Chromium OK', b.version); b.close(); p.stop()"
codesign --verify --deep --strict "$APP"
echo "✓ Signature remains valid after Chromium smoke test"

mkdir -p "$ARTIFACT_DIR"
GYRUS_APP_PATH="$APP" GYRUS_ARTIFACT_DIR="$ARTIFACT_DIR" ./package_dmg.sh
DMG="$ARTIFACT_DIR/Gyrus.dmg"
EXTENSION_ARCHIVE="$ARTIFACT_DIR/Gyrus-Saver-v$RELEASE_VERSION.zip"
CHECKSUMS="$ARTIFACT_DIR/SHA256SUMS.txt"
rm -f "$EXTENSION_ARCHIVE" "$CHECKSUMS"
/usr/bin/ditto -c -k --keepParent extension "$EXTENSION_ARCHIVE"
(cd "$ARTIFACT_DIR" && shasum -a 256 Gyrus.dmg "$(basename "$EXTENSION_ARCHIVE")" > SHA256SUMS.txt)
echo "✓ Release artifacts ready in $ARTIFACT_DIR"
cat "$CHECKSUMS"

# --- Optional publish -------------------------------------------------------
if [[ "$PUBLISH" == "--publish" ]]; then
    git add "$PBXPROJ" "$MANIFEST" "$INFO_PLIST" "$SETTINGS" "$GENERATOR" "$BACKEND_MAIN" "$README" CHANGELOG.md
    git commit -m "chore: release $TAG"
    git tag "$TAG"
    git push origin main
    git push origin "$TAG"
    # Release notes = the CHANGELOG section for this version (English by convention).
    NOTES_FILE="$ARTIFACT_DIR/release-notes.md"
    awk "/## \[$RELEASE_VERSION\]/{flag=1; next} /^## \[/{flag=0} flag" CHANGELOG.md > "$NOTES_FILE"
    printf '\n---\n\n**App:** Open the DMG and drag Gyrus to Applications. Gyrus is ad-hoc signed but not notarized; follow the Gatekeeper instructions in the README on first launch.\n\n**Browser extension:** Unzip `Gyrus-Saver-v%s.zip`, enable Developer mode in your Chromium browser, and load the included `extension` folder as an unpacked extension.\n' "$RELEASE_VERSION" >> "$NOTES_FILE"
    RELEASE_FLAGS=()
    if [[ -n "$RELEASE_CHANNEL" ]]; then
        RELEASE_FLAGS+=(--prerelease)
    else
        RELEASE_FLAGS+=(--latest)
    fi
    gh release create "$TAG" "$DMG" "$EXTENSION_ARCHIVE" "$CHECKSUMS" \
        --title "Gyrus $TAG" "${RELEASE_FLAGS[@]}" --notes-file "$NOTES_FILE"
    echo "✓ Published: $(gh release view "$TAG" --json url -q .url)"
else
    echo "▶ Dry run done. Review the app and artifacts."
    echo "  Commit or restore the version changes before publishing from clean main."
fi
