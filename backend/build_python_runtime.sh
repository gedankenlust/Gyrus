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

PY_SERIES="3.11"
RUNTIME_DIR="python-runtime"

ARCH="$(uname -m)"
case "$ARCH" in
  arm64)  TRIPLE="aarch64-apple-darwin" ;;
  x86_64) TRIPLE="x86_64-apple-darwin" ;;
  *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac

echo "→ Finding latest python-build-standalone ($PY_SERIES, $TRIPLE)…"
API="https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest"
# Prefer the smaller "install_only_stripped" build. The '+' in the version is
# URL-encoded as %2B in the asset URL.
ASSET_URL="$(curl -fsSL "$API" \
  | grep -oE "https://[^\"]*cpython-${PY_SERIES}\.[0-9]+(%2B|\+)[0-9]+-${TRIPLE}-install_only_stripped\.tar\.gz" \
  | head -1)"

if [ -z "$ASSET_URL" ]; then
  echo "Could not find a matching standalone Python asset." >&2
  exit 1
fi
echo "  $ASSET_URL"

echo "→ Downloading…"
TMP_TGZ="$(mktemp -t pybs).tar.gz"
curl -fsSL "$ASSET_URL" -o "$TMP_TGZ"

echo "→ Extracting to $RUNTIME_DIR/…"
rm -rf "$RUNTIME_DIR"
mkdir -p "$RUNTIME_DIR"
# The archive contains a top-level python/ dir → strip it.
tar -xzf "$TMP_TGZ" -C "$RUNTIME_DIR" --strip-components=1
rm -f "$TMP_TGZ"

PY="$RUNTIME_DIR/bin/python3"
echo "→ Installing production dependencies into the runtime…"
"$PY" -m pip install --upgrade pip >/dev/null
# Install everything except the dev/test tools (kept out of the shipped runtime).
grep -ivE '^(pytest|pytest-asyncio)' requirements.txt > "$RUNTIME_DIR/.prod-requirements.txt"
"$PY" -m pip install -r "$RUNTIME_DIR/.prod-requirements.txt"

echo "→ Slimming…"
# Drop caches and test dirs to keep the bundle smaller.
find "$RUNTIME_DIR" -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true
find "$RUNTIME_DIR" -type d -name "tests" -path "*/site-packages/*" -prune -exec rm -rf {} + 2>/dev/null || true

echo "→ Verifying uvicorn imports from the bundled runtime…"
"$PY" -c "import uvicorn, fastapi, sqlalchemy, PIL, lxml; print('OK', uvicorn.__version__)"

SIZE="$(du -sh "$RUNTIME_DIR" | cut -f1)"
echo "✅ Done. Runtime at backend/$RUNTIME_DIR ($SIZE). Re-run generate_xcodeproj.py is not needed; just rebuild the app."
