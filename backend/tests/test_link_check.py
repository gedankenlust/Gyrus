"""Tests for dead-link detection.

The core rule: a timeout or transient network error must NEVER mark a link
dead on its own — only a definitive 404/410 or a connection failure that
persists across every retry. Marking dead on a single timeout produced
different results on every run and deleted healthy bookmarks.
"""
import httpx
import pytest

from services import link_check_service
from services.link_check_service import _check_url, is_local_host


def _client(handler):
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


@pytest.mark.asyncio
async def test_404_is_dead():
    async with _client(lambda r: httpx.Response(404)) as c:
        assert await _check_url(c, "https://example.com/gone") is True


@pytest.mark.asyncio
async def test_410_is_dead():
    async with _client(lambda r: httpx.Response(410)) as c:
        assert await _check_url(c, "https://example.com/gone") is True


@pytest.mark.asyncio
async def test_200_is_alive():
    async with _client(lambda r: httpx.Response(200)) as c:
        assert await _check_url(c, "https://example.com/") is False


@pytest.mark.asyncio
async def test_403_is_not_dead():
    # Auth-walled pages respond 403 but the link itself is fine.
    async with _client(lambda r: httpx.Response(403)) as c:
        assert await _check_url(c, "https://example.com/private") is False


@pytest.mark.asyncio
async def test_timeout_is_not_dead(monkeypatch):
    monkeypatch.setattr(link_check_service, "RETRY_DELAY", 0)

    def handler(request):
        raise httpx.ConnectTimeout("slow", request=request)

    async with _client(handler) as c:
        # A slow / timing-out server is not a dead link.
        assert await _check_url(c, "https://slow.example.com/") is False


@pytest.mark.asyncio
async def test_persistent_connect_error_is_dead(monkeypatch):
    monkeypatch.setattr(link_check_service, "RETRY_DELAY", 0)

    def handler(request):
        raise httpx.ConnectError("name not resolved", request=request)

    async with _client(handler) as c:
        assert await _check_url(c, "https://gone.invalid/") is True


@pytest.mark.parametrize("url", [
    "http://localhost:3000",
    "http://127.0.0.1:8080/app",
    "http://[::1]:9000",
    "http://192.168.1.5",
    "http://10.0.0.2/x",
    "http://172.16.5.5",
    "http://nas.local",
    "http://devbox/dashboard",  # bare hostname = local network name
])
def test_local_hosts_are_recognized(url):
    assert is_local_host(url) is True


@pytest.mark.parametrize("url", [
    "https://example.com",
    "https://github.com/x",
    "http://172.32.0.1",  # just outside the private 172.16/12 range
])
def test_public_hosts_are_not_local(url):
    assert is_local_host(url) is False


@pytest.mark.asyncio
async def test_localhost_is_never_dead(monkeypatch):
    monkeypatch.setattr(link_check_service, "RETRY_DELAY", 0)

    def handler(request):
        # A local dev server that's currently off → connection refused.
        raise httpx.ConnectError("connection refused", request=request)

    async with _client(handler) as c:
        # Would be "dead" by the persistent-ConnectError rule, but local hosts
        # are skipped entirely — a stopped dev server is not a dead link.
        assert await _check_url(c, "http://localhost:3000") is False


@pytest.mark.asyncio
async def test_transient_timeout_recovers(monkeypatch):
    monkeypatch.setattr(link_check_service, "RETRY_DELAY", 0)
    calls = {"n": 0}

    def handler(request):
        calls["n"] += 1
        if calls["n"] == 1:
            raise httpx.ConnectTimeout("first try", request=request)
        return httpx.Response(200)

    async with _client(handler) as c:
        # First attempt times out, retry succeeds → alive.
        assert await _check_url(c, "https://flaky.example.com/") is False
    assert calls["n"] == 2
