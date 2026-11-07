import asyncio
import socket

import pytest

from services.safe_egress_proxy import SafeEgressProxy


async def _proxy_request(proxy: SafeEgressProxy, payload: bytes) -> bytes:
    parsed = proxy.url.rsplit(":", 1)
    reader, writer = await asyncio.open_connection("127.0.0.1", int(parsed[-1]))
    writer.write(payload)
    await writer.drain()
    response = await asyncio.wait_for(reader.read(), timeout=2.0)
    writer.close()
    await writer.wait_closed()
    return response


@pytest.mark.asyncio
async def test_proxy_blocks_private_destination_for_public_pages():
    async with SafeEgressProxy() as proxy:
        response = await _proxy_request(
            proxy,
            b"CONNECT 127.0.0.1:8080 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        )

    assert response.startswith(b"HTTP/1.1 403")


@pytest.mark.asyncio
async def test_proxy_connects_to_the_single_validated_address(monkeypatch):
    async def upstream(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
        await reader.readuntil(b"\r\n\r\n")
        writer.write(
            b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"
        )
        await writer.drain()
        writer.close()
        await writer.wait_closed()

    server = await asyncio.start_server(upstream, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    resolutions = 0

    def resolve_once(*_args, **_kwargs):
        nonlocal resolutions
        resolutions += 1
        address = "127.0.0.1" if resolutions == 1 else "10.0.0.1"
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (address, port))]

    monkeypatch.setattr(socket, "getaddrinfo", resolve_once)
    try:
        async with SafeEgressProxy(allowed_private_host="rebind.test") as proxy:
            response = await _proxy_request(
                proxy,
                (
                    f"GET http://rebind.test:{port}/ HTTP/1.1\r\n"
                    f"Host: rebind.test:{port}\r\n\r\n"
                ).encode("ascii"),
            )
    finally:
        server.close()
        await server.wait_closed()

    assert response.endswith(b"OK")
    assert resolutions == 1


def _unused_local_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


@pytest.mark.asyncio
@pytest.mark.parametrize("request_line", [
    b"CONNECT gone.test:443 HTTP/1.1\r\nHost: gone.test\r\n\r\n",
    b"GET http://gone.test/ HTTP/1.1\r\nHost: gone.test\r\n\r\n",
])
async def test_proxy_reports_unresolvable_host_as_unreachable(monkeypatch, request_line):
    def nxdomain(*_args, **_kwargs):
        raise socket.gaierror(socket.EAI_NONAME, "not known")

    monkeypatch.setattr(socket, "getaddrinfo", nxdomain)
    async with SafeEgressProxy() as proxy:
        response = await _proxy_request(proxy, request_line)

    assert response.startswith(b"HTTP/1.1 502 Destination Unreachable\r\n")
    assert b"\r\nX-Gyrus-Egress: unreachable\r\n" in response


@pytest.mark.asyncio
async def test_proxy_reports_refused_upstream_as_unreachable(monkeypatch):
    port = _unused_local_port()

    def resolve(*_args, **_kwargs):
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", port))]

    monkeypatch.setattr(socket, "getaddrinfo", resolve)
    async with SafeEgressProxy(allowed_private_host="closed.test") as proxy:
        response = await _proxy_request(
            proxy, f"CONNECT closed.test:{port} HTTP/1.1\r\nHost: closed.test\r\n\r\n".encode()
        )

    assert response.startswith(b"HTTP/1.1 502 ")
    assert b"X-Gyrus-Egress: unreachable" in response


@pytest.mark.asyncio
async def test_proxy_labels_policy_refusals_as_blocked():
    async with SafeEgressProxy() as proxy:
        response = await _proxy_request(
            proxy, b"GET http://127.0.0.1:9/ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        )

    assert response.startswith(b"HTTP/1.1 403 ")
    assert b"X-Gyrus-Egress: blocked" in response
