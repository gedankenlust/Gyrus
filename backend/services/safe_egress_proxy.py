"""Small DNS-pinning proxy for bookmark-controlled outbound traffic.

Validation and connection happen in one place: the proxy resolves a host,
checks every result, and connects to the exact approved IP instead of allowing
the HTTP client or browser to resolve the hostname a second time.
"""

from __future__ import annotations

import asyncio
import logging
from contextlib import AbstractAsyncContextManager
from urllib.parse import urlsplit

from services.outbound_url_security import (
    OutboundURLBlocked,
    resolve_outbound_addresses,
)

logger = logging.getLogger(__name__)

MAX_PROXY_HEADER_BYTES = 64 * 1024
PROXY_IO_TIMEOUT_SECONDS = 15.0
MAX_PROXY_CONNECTIONS = 64


class SafeEgressProxy(AbstractAsyncContextManager):
    def __init__(self, *, allowed_private_host: str | None = None):
        self.allowed_private_host = allowed_private_host
        self._server: asyncio.AbstractServer | None = None
        self._connections: set[asyncio.Task] = set()
        self._semaphore = asyncio.Semaphore(MAX_PROXY_CONNECTIONS)
        self._dns_cache: dict[tuple[str, int], tuple[str, ...]] = {}

    @property
    def url(self) -> str:
        if self._server is None or not self._server.sockets:
            raise RuntimeError("Safe egress proxy is not running")
        host, port = self._server.sockets[0].getsockname()[:2]
        return f"http://{host}:{port}"

    async def __aenter__(self):
        self._server = await asyncio.start_server(
            self._handle_client,
            "127.0.0.1",
            0,
            limit=MAX_PROXY_HEADER_BYTES,
        )
        return self

    async def __aexit__(self, exc_type, exc, tb):
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
            self._server = None
        tasks = [task for task in self._connections if not task.done()]
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        self._connections.clear()

    async def _handle_client(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        task = asyncio.current_task()
        if task is not None:
            self._connections.add(task)
        try:
            async with self._semaphore:
                await self._proxy_request(reader, writer)
        except (ConnectionError, asyncio.IncompleteReadError):
            pass
        except Exception:
            logger.debug("Safe egress proxy connection failed", exc_info=True)
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass
            if task is not None:
                self._connections.discard(task)

    async def _proxy_request(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        try:
            raw_headers = await asyncio.wait_for(
                reader.readuntil(b"\r\n\r\n"),
                timeout=PROXY_IO_TIMEOUT_SECONDS,
            )
        except (asyncio.TimeoutError, asyncio.LimitOverrunError):
            await self._send_error(writer, 408, "Proxy request timed out")
            return

        if len(raw_headers) > MAX_PROXY_HEADER_BYTES:
            await self._send_error(writer, 431, "Proxy headers too large")
            return

        try:
            first_line, *header_lines = raw_headers.decode("latin-1").split("\r\n")
            method, target, version = first_line.split(" ", 2)
        except ValueError:
            await self._send_error(writer, 400, "Malformed proxy request")
            return

        method = method.upper()
        if method == "CONNECT":
            try:
                destination = self._connect_url(target)
            except (OutboundURLBlocked, ValueError):
                await self._send_error(writer, 400, "Malformed CONNECT destination")
                return
            upstream = await self._open_approved_connection(destination)
            if upstream is None:
                await self._send_error(writer, 403, "Destination blocked")
                return
            upstream_reader, upstream_writer = upstream
            writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            await writer.drain()
            await self._relay(reader, writer, upstream_reader, upstream_writer)
            return

        parsed = urlsplit(target)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname:
            await self._send_error(writer, 400, "Absolute HTTP URL required")
            return
        if parsed.scheme == "https":
            await self._send_error(writer, 400, "HTTPS requires CONNECT")
            return

        upstream = await self._open_approved_connection(target)
        if upstream is None:
            await self._send_error(writer, 403, "Destination blocked")
            return
        upstream_reader, upstream_writer = upstream
        path = parsed.path or "/"
        if parsed.query:
            path += f"?{parsed.query}"
        forwarded_headers = [
            line
            for line in header_lines
            if line and not line.lower().startswith(("proxy-connection:", "connection:"))
        ]
        forwarded_headers.append("Connection: close")
        payload = (
            f"{method} {path} {version}\r\n"
            + "\r\n".join(forwarded_headers)
            + "\r\n\r\n"
        ).encode("latin-1")
        upstream_writer.write(payload)
        await upstream_writer.drain()
        await self._relay(reader, writer, upstream_reader, upstream_writer)

    async def _open_approved_connection(
        self, url: str
    ) -> tuple[asyncio.StreamReader, asyncio.StreamWriter] | None:
        try:
            parsed = urlsplit(url)
            addresses = await resolve_outbound_addresses(
                url,
                allowed_private_host=self.allowed_private_host,
                dns_cache=self._dns_cache,
            )
        except OutboundURLBlocked:
            return None

        try:
            port = parsed.port or (443 if parsed.scheme == "https" else 80)
        except ValueError:
            return None
        for address in addresses:
            try:
                return await asyncio.wait_for(
                    asyncio.open_connection(address, port),
                    timeout=PROXY_IO_TIMEOUT_SECONDS,
                )
            except (OSError, asyncio.TimeoutError):
                continue
        return None

    @staticmethod
    def _connect_url(authority: str) -> str:
        parsed = urlsplit(f"//{authority}")
        if not parsed.hostname or parsed.username is not None or parsed.password is not None:
            raise OutboundURLBlocked("Malformed CONNECT destination")
        port = parsed.port or 443
        host = parsed.hostname
        bracketed = f"[{host}]" if ":" in host else host
        return f"https://{bracketed}:{port}/"

    @staticmethod
    async def _relay(
        client_reader: asyncio.StreamReader,
        client_writer: asyncio.StreamWriter,
        upstream_reader: asyncio.StreamReader,
        upstream_writer: asyncio.StreamWriter,
    ) -> None:
        async def pipe(source: asyncio.StreamReader, destination: asyncio.StreamWriter):
            while True:
                chunk = await source.read(64 * 1024)
                if not chunk:
                    break
                destination.write(chunk)
                await destination.drain()

        tasks = {
            asyncio.create_task(pipe(client_reader, upstream_writer)),
            asyncio.create_task(pipe(upstream_reader, client_writer)),
        }
        try:
            done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                await task
            for task in pending:
                task.cancel()
            if pending:
                await asyncio.gather(*pending, return_exceptions=True)
        finally:
            upstream_writer.close()
            try:
                await upstream_writer.wait_closed()
            except Exception:
                pass

    @staticmethod
    async def _send_error(
        writer: asyncio.StreamWriter,
        status: int,
        message: str,
    ) -> None:
        body = message.encode("utf-8")
        writer.write(
            f"HTTP/1.1 {status} Error\r\n"
            f"Content-Length: {len(body)}\r\n"
            "Connection: close\r\n"
            "Content-Type: text/plain; charset=utf-8\r\n\r\n".encode("ascii")
            + body
        )
        await writer.drain()
