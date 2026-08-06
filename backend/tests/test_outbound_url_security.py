import socket

import httpx
import pytest

from schemas.bookmark import BookmarkCreate
from services.outbound_url_security import (
    OutboundURLBlocked,
    explicit_private_hostname,
    request_guard,
    validate_bookmark_url_syntax,
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


def test_validate_bookmark_url_syntax_valid_urls():
    assert validate_bookmark_url_syntax("https://example.com") == "https://example.com"
    assert validate_bookmark_url_syntax("http://example.com/path?query=1") == "http://example.com/path?query=1"
    assert validate_bookmark_url_syntax("  https://example.com  ") == "https://example.com"

def test_validate_bookmark_url_syntax_invalid_schemes():
    with pytest.raises(OutboundURLBlocked, match="Only http:// and https:// URLs are allowed"):
        validate_bookmark_url_syntax("ftp://example.com")
    with pytest.raises(OutboundURLBlocked, match="Only http:// and https:// URLs are allowed"):
        validate_bookmark_url_syntax("file:///etc/passwd")

def test_validate_bookmark_url_syntax_missing_hostname():
    with pytest.raises(OutboundURLBlocked, match="Only http:// and https:// URLs are allowed"):
        validate_bookmark_url_syntax("https://")

def test_validate_bookmark_url_syntax_credentials():
    with pytest.raises(OutboundURLBlocked, match="Credentials in URLs are not allowed"):
        validate_bookmark_url_syntax("https://user:password@example.com")

def test_validate_bookmark_url_syntax_length_limit():
    long_url = "https://example.com/" + "a" * 8192
    with pytest.raises(OutboundURLBlocked, match="URL is missing or too long"):
        validate_bookmark_url_syntax(long_url)

def test_validate_bookmark_url_syntax_non_string():
    with pytest.raises(OutboundURLBlocked, match="URL is missing or too long"):
        validate_bookmark_url_syntax(None) # type: ignore
