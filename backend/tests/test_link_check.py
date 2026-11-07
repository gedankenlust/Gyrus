"""Tests for dead-link detection.

The core rule: a timeout or transient network error must NEVER mark a link
dead on its own — only a definitive 404/410 or a connection failure that
persists across every retry. Marking dead on a single timeout produced
different results on every run and deleted healthy bookmarks.
"""
import httpx
import pytest
import ssl

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
async def test_get_fallback_does_not_download_response_body():
    class MustNotRead(httpx.AsyncByteStream):
        async def __aiter__(self):
            raise AssertionError("link checker consumed the response body")
            yield b""

    def handler(request):
        if request.method == "HEAD":
            return httpx.Response(405)
        return httpx.Response(200, stream=MustNotRead())

    async with _client(handler) as c:
        assert await _check_url(c, "https://example.com/no-head") is False


@pytest.mark.asyncio
async def test_timeout_is_not_dead(monkeypatch):
    monkeypatch.setattr(link_check_service, "RETRY_DELAY", 0)

    def handler(request):
        raise httpx.ConnectTimeout("slow", request=request)

    async with _client(handler) as c:
        # A slow / timing-out server is not a dead link.
        assert await _check_url(c, "https://slow.example.com/") is None


@pytest.mark.asyncio
async def test_persistent_connect_error_is_dead(monkeypatch):
    monkeypatch.setattr(link_check_service, "RETRY_DELAY", 0)

    def handler(request):
        raise httpx.ConnectError("name not resolved", request=request)

    async with _client(handler) as c:
        assert await _check_url(c, "https://gone.invalid/") is True


@pytest.mark.asyncio
async def test_invalid_tls_keeps_previous_status(monkeypatch):
    monkeypatch.setattr(link_check_service, "RETRY_DELAY", 0)

    def handler(request):
        try:
            raise ssl.SSLCertVerificationError("certificate verify failed")
        except ssl.SSLCertVerificationError as cause:
            raise httpx.ConnectError("TLS failed", request=request) from cause

    async with _client(handler) as c:
        assert await _check_url(c, "https://expired.example/") is None


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


# --- Real guard + safe egress proxy path -----------------------------------
# MockTransport bypasses the proxy entirely, which is how dead hosts used to
# look alive: the proxy answered 403 "Destination blocked" for a host that no
# longer resolved or refused connections. These tests go through the actual
# request guard, SafeEgressProxy and httpx proxy handling.

import asyncio
import socket

from services.outbound_url_security import OutboundHostUnresolvable, OutboundURLBlocked
from services.safe_egress_proxy import SafeEgressProxy

PUBLIC_ADDRESS = "93.184.216.34"


def _unused_local_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def _resolve_to(address: str):
    def getaddrinfo(host, port, *args, **kwargs):
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (address, port))]
    return getaddrinfo


def _nxdomain(errno: int = socket.EAI_NONAME):
    def getaddrinfo(*args, **kwargs):
        raise socket.gaierror(errno, "nodename nor servname provided, or not known")
    return getaddrinfo


def _redirect_upstream(monkeypatch, port: int) -> list:
    """Keep the public address in DNS/policy, but dial a local port instead."""
    dialed = []

    async def connect(address, _port):
        dialed.append(address)
        return await asyncio.open_connection("127.0.0.1", port)

    monkeypatch.setattr(SafeEgressProxy, "_connect", staticmethod(connect))
    return dialed


async def _check_through_proxy(url: str):
    async with SafeEgressProxy() as proxy, link_check_service._make_client(proxy.url) as client:
        return await _check_url(client, url)


def test_unresolvable_host_is_a_blocked_subclass():
    # Scraper/metadata callers catch OutboundURLBlocked and keep working.
    assert issubclass(OutboundHostUnresolvable, OutboundURLBlocked)


@pytest.mark.asyncio
@pytest.mark.parametrize("url", ["https://gone.example/", "http://gone.example/"])
async def test_nxdomain_is_dead_through_guard_and_proxy(monkeypatch, url):
    monkeypatch.setattr(link_check_service, "RETRY_DELAY", 0)
    monkeypatch.setattr(socket, "getaddrinfo", _nxdomain())
    assert await _check_through_proxy(url) is True


@pytest.mark.asyncio
async def test_temporary_dns_failure_keeps_previous_status(monkeypatch):
    monkeypatch.setattr(link_check_service, "RETRY_DELAY", 0)
    monkeypatch.setattr(socket, "getaddrinfo", _nxdomain(socket.EAI_AGAIN))
    assert await _check_through_proxy("https://flaky-dns.example/") is None


@pytest.mark.asyncio
@pytest.mark.parametrize("url", ["https://refused.example/", "http://refused.example/"])
async def test_refused_connection_is_dead_through_proxy(monkeypatch, url):
    # https: CONNECT gets 502 -> httpx.ProxyError; http: a 502 response with
    # X-Gyrus-Egress: unreachable (this used to be a 403 -> "alive").
    monkeypatch.setattr(link_check_service, "RETRY_DELAY", 0)
    monkeypatch.setattr(socket, "getaddrinfo", _resolve_to(PUBLIC_ADDRESS))
    dialed = _redirect_upstream(monkeypatch, _unused_local_port())
    assert await _check_through_proxy(url) is True
    assert dialed and set(dialed) == {PUBLIC_ADDRESS}


@pytest.mark.asyncio
async def test_reachable_plain_http_site_is_alive_through_proxy(monkeypatch):
    async def upstream(reader, writer):
        await reader.readuntil(b"\r\n\r\n")
        writer.write(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        await writer.drain()
        writer.close()

    server = await asyncio.start_server(upstream, "127.0.0.1", 0)
    monkeypatch.setattr(socket, "getaddrinfo", _resolve_to(PUBLIC_ADDRESS))
    _redirect_upstream(monkeypatch, server.sockets[0].getsockname()[1])
    try:
        assert await _check_through_proxy("http://alive.example/") is False
    finally:
        server.close()
        await server.wait_closed()


@pytest.mark.asyncio
@pytest.mark.parametrize("url", ["https://rebound.example/", "http://rebound.example/"])
async def test_policy_blocked_destination_keeps_previous_status(monkeypatch, url):
    monkeypatch.setattr(link_check_service, "RETRY_DELAY", 0)
    monkeypatch.setattr(socket, "getaddrinfo", _resolve_to("10.0.0.1"))
    assert await _check_through_proxy(url) is None


@pytest.mark.asyncio
async def test_proxy_blocked_after_guard_passed_keeps_previous_status(monkeypatch):
    # DNS changes between the guard's lookup and the proxy's (rebinding): the
    # proxy's own policy refusal is labelled "blocked", never "alive"/"dead".
    monkeypatch.setattr(link_check_service, "RETRY_DELAY", 0)
    answers = iter([PUBLIC_ADDRESS, "10.0.0.1"] * 10)

    def rebinding(host, port, *args, **kwargs):
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (next(answers), port))]

    monkeypatch.setattr(socket, "getaddrinfo", rebinding)
    assert await _check_through_proxy("http://rebind.example/") is None
