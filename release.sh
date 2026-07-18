#!/usr/bin/env bash
#
# Gyrus release script — bumps every version location, builds, packages, tags.
#
#   ./release.sh 1.3.2            # bump + build + artifacts (no tag/release)
#   ./release.sh 1.3.2 --publish  # …plus commit, tag, push, GitHub release
#
# Version locations kept in sync (previously edited by hand, easy to miss one):
#   - Gyrus.xcodeproj/project.pbxproj  MARKETING_VERSION (2×) + CURRENT_PROJECT_VERSION (2×)
#   - extension/manifest.json          "version"
#   - Gyrus/Views/Settings/SettingsView.swift  About-pane fallback string
#   - generate_xcodeproj.py            generated-project version and build
#   - backend/main.py                  API/health version
#   - README.md                        badge and extension archive name
#   - CHANGELOG.md                     must already contain a [X.Y.Z] section
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
PUBLISH="${2:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: ./release.sh <version> [--publish]   e.g. ./release.sh 1.3.2"
    exit 1
fi

PBXPROJ="Gyrus.xcodeproj/project.pbxproj"
MANIFEST="extension/manifest.json"
SETTINGS="Gyrus/Views/Settings/SettingsView.swift"
GENERATOR="generate_xcodeproj.py"
BACKEND_MAIN="backend/main.py"
README="README.md"

# --- Preflight -------------------------------------------------------------
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "❌ Tag v$VERSION already exists."; exit 1
fi
if ! grep -q "## \[$VERSION\]" CHANGELOG.md; then
    echo "❌ CHANGELOG.md has no '## [$VERSION]' section. Write the changelog first."; exit 1
fi
if [[ "$PUBLISH" == "--publish" && -n "$(git status --porcelain)" ]]; then
    echo "❌ Working tree not clean — commit or stash before publishing."; exit 1
fi

OLD_VERSION=$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' "$PBXPROJ" | head -1)
OLD_BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \(.*\);/\1/p' "$PBXPROJ" | head -1)
NEW_BUILD=$((OLD_BUILD + 1))
echo "▶ $OLD_VERSION (build $OLD_BUILD) → $VERSION (build $NEW_BUILD)"

# --- Bump every version location -------------------------------------------
sed -i '' "s/MARKETING_VERSION = $OLD_VERSION;/MARKETING_VERSION = $VERSION;/g" "$PBXPROJ"
sed -i '' "s/CURRENT_PROJECT_VERSION = $OLD_BUILD;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" "$PBXPROJ"
sed -i '' "s/\"version\": \"[0-9.]*\",/\"version\": \"$VERSION\",/" "$MANIFEST"
# Only the marketing-version fallback line — the About pane also has a
# CFBundleVersion fallback ('?? "1"') that must not become "1.3.0".
sed -i '' "/CFBundleShortVersionString/s/?? \"[0-9.]*\"/?? \"$VERSION\"/" "$SETTINGS"
sed -i '' -E "s/^MARKETING_VERSION = \"[0-9.]+\"/MARKETING_VERSION = \"$VERSION\"/" "$GENERATOR"
sed -i '' -E "s/^BUILD_VERSION = \"[0-9]+\"/BUILD_VERSION = \"$NEW_BUILD\"/" "$GENERATOR"
sed -i '' -E "s/^APP_VERSION = \"[0-9.]+\"/APP_VERSION = \"$VERSION\"/" "$BACKEND_MAIN"
sed -i '' -E "s/version-[0-9]+\.[0-9]+\.[0-9]+-brightgreen/version-$VERSION-brightgreen/" "$README"
sed -i '' -E "s/Gyrus-Saver-v[0-9]+\.[0-9]+\.[0-9]+\.zip/Gyrus-Saver-v$VERSION.zip/g" "$README"

# Verify nothing was missed
for f in "$PBXPROJ" "$MANIFEST" "$SETTINGS" "$GENERATOR" "$BACKEND_MAIN" "$README"; do
    if ! grep -q "$VERSION" "$f"; then echo "❌ Bump failed in $f"; exit 1; fi
done
echo "✓ App, backend, extension, generator, and README versions synchronized"

# --- Build + package --------------------------------------------------------
echo "▶ Security and regression tests…"
backend/venv/bin/python -m pytest -q backend/tests
xcodebuild test -project Gyrus.xcodeproj -scheme Gyrus \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO

echo "▶ Release build…"
rm -rf build/Build/Products/Release/Gyrus.app
xcodebuild -scheme Gyrus -configuration Release -derivedDataPath build \
    -destination 'platform=macOS' build

APP="build/Build/Products/Release/Gyrus.app"
BUILT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
if [[ "$BUILT" != "$VERSION" ]]; then
    echo "❌ Built bundle reports $BUILT, expected $VERSION"; exit 1
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

./package_dmg.sh
EXTENSION_ARCHIVE="Gyrus-Saver-v$VERSION.zip"
rm -f "$EXTENSION_ARCHIVE" SHA256SUMS.txt
/usr/bin/ditto -c -k --keepParent extension "$EXTENSION_ARCHIVE"
shasum -a 256 Gyrus.dmg "$EXTENSION_ARCHIVE" > SHA256SUMS.txt
echo "✓ Gyrus.dmg and $EXTENSION_ARCHIVE ready"
cat SHA256SUMS.txt

# --- Optional publish -------------------------------------------------------
if [[ "$PUBLISH" == "--publish" ]]; then
    git add "$PBXPROJ" "$MANIFEST" "$SETTINGS" "$GENERATOR" "$BACKEND_MAIN" "$README" CHANGELOG.md
    git commit -m "chore: release v$VERSION"
    git tag "v$VERSION"
    git push origin main
    git push origin "v$VERSION"
    # Release notes = the CHANGELOG section for this version (English by convention).
    awk "/## \[$VERSION\]/{flag=1; next} /^## \[/{flag=0} flag" CHANGELOG.md > /tmp/relnotes.md
    printf '\n---\n\n**App:** Open the DMG and drag Gyrus to Applications. Gyrus is ad-hoc signed but not notarized; follow the Gatekeeper instructions in the README on first launch.\n\n**Browser extension:** Unzip `Gyrus-Saver-v%s.zip`, enable Developer mode in your Chromium browser, and load the included `extension` folder as an unpacked extension.\n' "$VERSION" >> /tmp/relnotes.md
    gh release create "v$VERSION" Gyrus.dmg "$EXTENSION_ARCHIVE" SHA256SUMS.txt --title "Gyrus v$VERSION" --latest --notes-file /tmp/relnotes.md
    echo "✓ Published: $(gh release view "v$VERSION" --json url -q .url)"
else
    echo "▶ Dry run done. Review, then: git commit; ./release.sh $VERSION --publish (or tag manually)"
fi
