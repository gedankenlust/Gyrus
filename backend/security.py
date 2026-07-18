"""Security boundary for the localhost API and outbound web requests."""

from __future__ import annotations

import hmac
import os
import secrets


DEFAULT_EXTENSION_ORIGIN = "chrome-extension://eoffmpeogpjblmimnhmhddelahenfdpg"
EXTENSION_ORIGINS = tuple(
    origin.strip()
    for origin in os.environ.get("GYRUS_EXTENSION_ORIGINS", DEFAULT_EXTENSION_ORIGIN).split(",")
    if origin.strip()
)

# This token lives only for the backend process lifetime. The trusted extension
# obtains it through a route that browsers can call only from its fixed origin.
API_TOKEN = os.environ.get("GYRUS_API_TOKEN") or secrets.token_urlsafe(32)


def is_trusted_extension_origin(origin: str | None) -> bool:
    return bool(origin and origin in EXTENSION_ORIGINS)


def has_valid_api_token(value: str | None) -> bool:
    return bool(value and hmac.compare_digest(value, API_TOKEN))
