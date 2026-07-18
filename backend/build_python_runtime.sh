#!/usr/bin/env bash
#
# Build a self-contained, relocatable Python runtime with all production
# dependencies pre-installed, so the shipped .app runs on any Mac WITHOUT a
# system Python or pip (no first-launch bootstrap).
#
# Run this once (and again whenever requirements.txt changes):
#   ./build_python_runtime.sh
#
# The result lands in backend/python-runtime/ (gitignored). The Xcode build
# phase bundles it into the .app; BackendLauncher prefers it when present.
#
set -euo pipefail
cd "$(dirname "$0")"   # backend/

PY_VERSION="3.11.15"
PY_BUILD_TAG="20260623"
PIP_VERSION="26.1.2"
RUNTIME_DIR="python-runtime"

ARCH="$(uname -m)"
case "$ARCH" in
  arm64)
    TRIPLE="aarch64-apple-darwin"
    EXPECTED_SHA256="2318799eaf104f8a29bc09a93b0851b05dbbcb4ce9a5f045ddea169c0c7ff3a5"
    ;;
  x86_64)
    TRIPLE="x86_64-apple-darwin"
    EXPECTED_SHA256="4925e5aaa9bc77c85302d350b36c1d9def2002996a6bcfa55c88ba6eb318de29"
    ;;
  *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

ASSET="cpython-${PY_VERSION}%2B${PY_BUILD_TAG}-${TRIPLE}-install_only_stripped.tar.gz"
ASSET_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PY_BUILD_TAG}/${ASSET}"
echo "→ Using pinned python-build-standalone ($PY_VERSION+$PY_BUILD_TAG, $TRIPLE)…"
echo "  $ASSET_URL"

echo "→ Downloading…"
TMP_TGZ="$(mktemp -t pybs).tar.gz"
curl -fsSL "$ASSET_URL" -o "$TMP_TGZ"
ACTUAL_SHA256="$(shasum -a 256 "$TMP_TGZ" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
  echo "Python runtime checksum mismatch." >&2
  rm -f "$TMP_TGZ"
  exit 1
fi
echo "  SHA-256 verified"

echo "→ Extracting to $RUNTIME_DIR/…"
rm -rf "$RUNTIME_DIR"
mkdir -p "$RUNTIME_DIR"
# The archive contains a top-level python/ dir → strip it.
tar -xzf "$TMP_TGZ" -C "$RUNTIME_DIR" --strip-components=1
rm -f "$TMP_TGZ"

PY="$RUNTIME_DIR/bin/python3"
echo "→ Installing production dependencies into the runtime…"
"$PY" -m pip install "pip==$PIP_VERSION" >/dev/null
# Install everything except the dev/test tools (kept out of the shipped runtime).
grep -ivE '^(pytest|pytest-asyncio)' requirements.txt > "$RUNTIME_DIR/.prod-requirements.txt"
"$PY" -m pip install -r "$RUNTIME_DIR/.prod-requirements.txt"

echo "→ Installing the bundled Chromium browser…"
PLAYWRIGHT_BROWSERS_PATH="$RUNTIME_DIR/playwright-browsers" \
  "$PY" -m playwright install --only-shell chromium

echo "→ Slimming…"
# Drop caches and test dirs to keep the bundle smaller.
find "$RUNTIME_DIR" -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true
find "$RUNTIME_DIR" -type d -name "tests" -path "*/site-packages/*" -prune -exec rm -rf {} + 2>/dev/null || true

echo "→ Verifying backend and browser imports from the bundled runtime…"
PYTHONDONTWRITEBYTECODE=1 PLAYWRIGHT_BROWSERS_PATH="$RUNTIME_DIR/playwright-browsers" \
  "$PY" -c "import uvicorn, fastapi, sqlalchemy, PIL, lxml, playwright; print('OK', uvicorn.__version__)"
PYTHONDONTWRITEBYTECODE=1 PLAYWRIGHT_BROWSERS_PATH="$RUNTIME_DIR/playwright-browsers" \
  "$PY" -c "from playwright.sync_api import sync_playwright; p=sync_playwright().start(); b=p.chromium.launch(headless=True); print('Chromium OK', b.version); b.close(); p.stop()"

# Verification must not leave mutable bytecode inside the runtime that Xcode
# later seals into the app bundle.
find "$RUNTIME_DIR" -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true
find "$RUNTIME_DIR" -type f -name "*.pyc" -delete 2>/dev/null || true

SIZE="$(du -sh "$RUNTIME_DIR" | cut -f1)"
echo "✅ Done. Runtime at backend/$RUNTIME_DIR ($SIZE). Re-run generate_xcodeproj.py is not needed; just rebuild the app."
