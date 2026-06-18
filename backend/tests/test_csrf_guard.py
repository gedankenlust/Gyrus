"""The local backend must reject requests from web pages (localhost CSRF).

CORS only stops a malicious site from reading responses; it does not stop a
"simple" cross-origin POST (no preflight) from triggering a side effect such as
wiping the database. A server-side Origin check is the actual guard.
"""
from fastapi.testclient import TestClient

import main

# No lifespan (not used as a context manager), so no migrations/backups run and
# the real DB is never touched — the 403 cases short-circuit before any route.
client = TestClient(main.app)


def test_request_without_origin_is_allowed():
    # The native app sends no Origin header.
    assert client.get("/health").status_code == 200


def test_browser_extension_origin_is_allowed():
    r = client.get("/health", headers={"Origin": "chrome-extension://abcdefghijklmnop"})
    assert r.status_code == 200


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
