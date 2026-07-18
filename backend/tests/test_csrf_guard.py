"""The local backend must reject requests from web pages (localhost CSRF).

CORS only stops a malicious site from reading responses; it does not stop a
"simple" cross-origin POST (no preflight) from triggering a side effect such as
wiping the database. A server-side Origin check is the actual guard.
"""
import base64
import hashlib
import json
from pathlib import Path

from fastapi.testclient import TestClient

import main

# No lifespan (not used as a context manager), so no migrations/backups run and
# the real DB is never touched — the 403 cases short-circuit before any route.
client = TestClient(main.app)


def test_extension_manifest_key_matches_allowed_chrome_origin():
    manifest_path = Path(__file__).parents[2] / "extension" / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    digest = hashlib.sha256(base64.b64decode(manifest["key"])).hexdigest()[:32]
    extension_id = "".join(chr(ord("a") + int(char, 16)) for char in digest)
    assert f"chrome-extension://{extension_id}" in main.EXTENSION_ORIGINS


def test_request_without_origin_is_allowed():
    # The native app sends no Origin header.
    assert client.get("/health").status_code == 200


def test_gyrus_extension_health_is_allowed():
    r = client.get("/health", headers={"Origin": main.EXTENSION_ORIGINS[0]})
    assert r.status_code == 200


def test_unrelated_browser_extension_is_blocked():
    r = client.get("/health", headers={"Origin": "chrome-extension://abcdefghijklmnop"})
    assert r.status_code == 403


def test_gyrus_extension_requires_process_token_for_api():
    origin = main.EXTENSION_ORIGINS[0]
    assert client.get("/api/bookmarks/count", headers={"Origin": origin}).status_code == 401
    token = client.get("/api/auth/extension-token", headers={"Origin": origin}).json()["token"]
    r = client.post(
        "/api/bookmarks",
        headers={"Origin": origin, "X-Gyrus-Token": token},
        json={},
    )
    assert r.status_code == 422


def test_gyrus_extension_cannot_read_or_reset_data():
    origin = main.EXTENSION_ORIGINS[0]
    token = client.get("/api/auth/extension-token", headers={"Origin": origin}).json()["token"]
    headers = {"Origin": origin, "X-Gyrus-Token": token}
    assert client.get("/api/data/backup", headers=headers).status_code == 403
    assert client.post("/api/data/factory-reset", headers=headers).status_code == 403


def test_web_origin_is_blocked():
    r = client.get("/health", headers={"Origin": "https://evil.example.com"})
    assert r.status_code == 403


def test_web_origin_blocked_on_destructive_endpoint():
    # The whole point: a malicious page must not be able to wipe data. The 403
    # fires in middleware before the route (and its DB session) is reached.
    r = client.post("/api/data/factory-reset", headers={"Origin": "https://evil.example.com"})
    assert r.status_code == 403


def test_http_localhost_web_origin_is_also_blocked():
    # Even another local web app (a page you have open) must not drive the API.
    r = client.post("/api/data/clear-bookmarks", headers={"Origin": "http://localhost:5173"})
    assert r.status_code == 403
