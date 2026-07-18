#!/usr/bin/env bash
#
# Gyrus release script — bumps every version location, builds, packages, tags.
#
#   ./release.sh 1.3.0            # bump + build + DMG (no tag/release)
#   ./release.sh 1.3.0 --publish  # …plus commit, tag, push, GitHub release
#
# Version locations kept in sync (previously edited by hand, easy to miss one):
#   - Gyrus.xcodeproj/project.pbxproj  MARKETING_VERSION (2×) + CURRENT_PROJECT_VERSION (2×)
#   - extension/manifest.json          "version"
#   - Gyrus/Views/Settings/SettingsView.swift  About-pane fallback string
#   - CHANGELOG.md                     must already contain a [X.Y.Z] section
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
PUBLISH="${2:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: ./release.sh <version> [--publish]   e.g. ./release.sh 1.3.0"
    exit 1
fi

PBXPROJ="Gyrus.xcodeproj/project.pbxproj"
MANIFEST="extension/manifest.json"
SETTINGS="Gyrus/Views/Settings/SettingsView.swift"

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

# Verify nothing was missed
for f in "$PBXPROJ" "$MANIFEST" "$SETTINGS"; do
    if ! grep -q "$VERSION" "$f"; then echo "❌ Bump failed in $f"; exit 1; fi
done
echo "✓ Versions bumped in pbxproj, manifest.json, SettingsView.swift"

# --- Build + package --------------------------------------------------------
echo "▶ Release build…"
xcodebuild -scheme Gyrus -configuration Release -derivedDataPath build \
    -destination 'platform=macOS' build 2>&1 | grep -E "^/.*error:|\*\* BUILD" || true

APP="build/Build/Products/Release/Gyrus.app"
BUILT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
if [[ "$BUILT" != "$VERSION" ]]; then
    echo "❌ Built bundle reports $BUILT, expected $VERSION"; exit 1
fi
echo "✓ Built Gyrus.app $BUILT (build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"))"

./package_dmg.sh
echo "✓ Gyrus.dmg ready"

# --- Optional publish -------------------------------------------------------
if [[ "$PUBLISH" == "--publish" ]]; then
    git add "$PBXPROJ" "$MANIFEST" "$SETTINGS" CHANGELOG.md
    git commit -m "chore: release v$VERSION"
    git tag "v$VERSION"
    git push origin main
    git push origin "v$VERSION"
    # Release notes = the CHANGELOG section for this version (English by convention).
    awk "/## \[$VERSION\]/{flag=1; next} /^## \[/{flag=0} flag" CHANGELOG.md > /tmp/relnotes.md
    printf '\n---\n\n**Install:** Open the DMG and drag Gyrus to Applications. Gyrus is unsigned — on first launch, right-click the app and choose **Open**, then confirm.\n' >> /tmp/relnotes.md
    gh release create "v$VERSION" Gyrus.dmg --title "Gyrus v$VERSION" --latest --notes-file /tmp/relnotes.md
    echo "✓ Published: $(gh release view "v$VERSION" --json url -q .url)"
else
    echo "▶ Dry run done. Review, then: git commit; ./release.sh $VERSION --publish (or tag manually)"
fi
