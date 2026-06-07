#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Gyrus Backend Setup"

if [ ! -d "venv" ]; then
    echo "--> Creating Python virtual environment..."
    python3 -m venv venv
fi

echo "--> Installing dependencies..."
source venv/bin/activate
pip install -r requirements.txt -q

echo "--> Running database migrations..."
alembic upgrade head

echo ""
echo "Setup complete. Start backend with:"
echo "  source venv/bin/activate && uvicorn main:app --host 127.0.0.1 --port 8080"
