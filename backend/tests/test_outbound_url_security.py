import socket

import httpx
import pytest

from schemas.bookmark import BookmarkCreate
from services.outbound_url_security import (
    OutboundURLBlocked,
    explicit_private_hostname,
    request_guard,
    validate_outbound_url,
)


def _dns(address: str):
    return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (address, 443))]


def test_bookmarks_require_http_or_https_url():
    with pytest.raises(ValueError):
        BookmarkCreate(title="Unsafe", url="file:///etc/passwd")
    with pytest.raises(ValueError):
        BookmarkCreate(title="Unsafe", url="javascript:alert(1)")


@pytest.mark.asyncio
async def test_public_host_is_allowed(monkeypatch):
    monkeypatch.setattr(socket, "getaddrinfo", lambda *args, **kwargs: _dns("93.184.216.34"))
    await validate_outbound_url("https://example.com/page")


@pytest.mark.asyncio
async def test_public_hostname_resolving_private_is_blocked(monkeypatch):
    monkeypatch.setattr(socket, "getaddrinfo", lambda *args, **kwargs: _dns("127.0.0.1"))
    with pytest.raises(OutboundURLBlocked):
        await validate_outbound_url("https://evil.example/redirect")


@pytest.mark.asyncio
async def test_explicit_local_bookmark_stays_available():
    url = "http://localhost:3000/design"
    await validate_outbound_url(url, allowed_private_host=explicit_private_hostname(url))


@pytest.mark.asyncio
async def test_public_request_hook_blocks_redirect_to_local(monkeypatch):
    monkeypatch.setattr(socket, "getaddrinfo", lambda *args, **kwargs: _dns("93.184.216.34"))
    guard = request_guard("https://example.com")
    await guard(httpx.Request("GET", "https://example.com/start"))
    with pytest.raises(OutboundURLBlocked):
        await guard(httpx.Request("GET", "http://127.0.0.1:8080/api/data/backup"))
