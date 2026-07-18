"""Validation hooks for requests made to bookmark-controlled URLs.

Public pages may load other public hosts, but they may never redirect or point
assets at localhost/private networks. A URL that the user explicitly saved as a
local address remains usable for local web-design work and is restricted to the
same hostname.
"""

from __future__ import annotations

import asyncio
import ipaddress
import socket
from urllib.parse import urlsplit

import httpx


class OutboundURLBlocked(ValueError):
    pass


def _parsed_http_url(url: str):
    if not isinstance(url, str) or len(url) > 8192:
        raise OutboundURLBlocked("URL is missing or too long")
    try:
        parsed = urlsplit(url.strip())
        port = parsed.port
    except ValueError as exc:
        raise OutboundURLBlocked("URL is malformed") from exc
    if parsed.scheme.lower() not in {"http", "https"} or not parsed.hostname:
        raise OutboundURLBlocked("Only http:// and https:// URLs are allowed")
    if parsed.username is not None or parsed.password is not None:
        raise OutboundURLBlocked("Credentials in URLs are not allowed")
    return parsed, port or (443 if parsed.scheme.lower() == "https" else 80)


def validate_bookmark_url_syntax(url: str) -> str:
    """Validate the cheap, synchronous part at the API boundary."""
    _parsed_http_url(url)
    return url.strip()


def explicit_private_hostname(url: str) -> str | None:
    """Return a local hostname only when it is explicit in the saved URL."""
    parsed, _ = _parsed_http_url(url)
    host = (parsed.hostname or "").lower().rstrip(".")
    if host == "localhost" or host.endswith(".local") or "." not in host:
        return host
    try:
        return host if not ipaddress.ip_address(host).is_global else None
    except ValueError:
        return None


async def validate_outbound_url(
    url: str,
    *,
    allowed_private_host: str | None = None,
    dns_cache: dict[tuple[str, int], tuple[str, ...]] | None = None,
) -> None:
    parsed, port = _parsed_http_url(url)
    host = (parsed.hostname or "").lower().rstrip(".")

    # Direct localhost/private bookmarks are an intentional designer feature.
    # They do not grant a public page permission to redirect to other LAN hosts.
    if allowed_private_host and host == allowed_private_host:
        return

    try:
        literal_address = ipaddress.ip_address(host)
    except ValueError:
        literal_address = None
    if literal_address is not None:
        if not literal_address.is_global:
            raise OutboundURLBlocked("Public pages may not access localhost or private networks")
        return

    key = (host, port)
    addresses = dns_cache.get(key) if dns_cache is not None else None
    if addresses is None:
        try:
            infos = await asyncio.to_thread(
                socket.getaddrinfo, host, port, type=socket.SOCK_STREAM
            )
        except socket.gaierror as exc:
            raise OutboundURLBlocked(f"Host could not be resolved: {host}") from exc
        addresses = tuple(sorted({item[4][0] for item in infos}))
        if dns_cache is not None:
            dns_cache[key] = addresses

    if not addresses:
        raise OutboundURLBlocked(f"Host could not be resolved: {host}")
    for value in addresses:
        try:
            address = ipaddress.ip_address(value)
        except ValueError as exc:
            raise OutboundURLBlocked(f"Host resolved to an invalid address: {host}") from exc
        if not address.is_global:
            raise OutboundURLBlocked("Public pages may not access localhost or private networks")


def request_guard(initial_url: str):
    """Create an httpx request hook that also checks every redirect."""
    allowed_private_host = explicit_private_hostname(initial_url)
    cache: dict[tuple[str, int], tuple[str, ...]] = {}

    async def guard(request: httpx.Request) -> None:
        await validate_outbound_url(
            str(request.url),
            allowed_private_host=allowed_private_host,
            dns_cache=cache,
        )

    return guard


async def strict_public_request_guard(request: httpx.Request) -> None:
    """Hook for mixed batches where local URLs were already skipped."""
    await validate_outbound_url(str(request.url))
