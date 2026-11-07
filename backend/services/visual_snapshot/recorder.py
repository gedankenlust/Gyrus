"""Observers attached to a page while one viewport renders.

The listeners only record bounded summaries: a hostile page can issue an
unbounded number of requests and console messages, and a script body is
inspected for fingerprints and then dropped.
"""

import asyncio
import logging
from typing import Any

from services.visual_snapshot.analysis.technologies import (
    declared_script_size,
    is_javascript_response,
    is_primary_script_bundle,
    script_content_markers,
    script_technology_versions,
)
from services.visual_snapshot.config import (
    MAX_CONSOLE_MESSAGES,
    MAX_NETWORK_ENTRIES,
    MAX_PRIMARY_SCRIPT_PROBES,
    MAX_TECHNOLOGY_SCRIPT_BYTES,
    MAX_TECHNOLOGY_SCRIPT_PROBES,
    MAX_TECHNOLOGY_SCRIPT_TOTAL_BYTES,
    SCRIPT_BODY_TIMEOUT_SECONDS,
)

logger = logging.getLogger(__name__)


class PageRecorder:
    """Collects network entries, console messages and script fingerprints."""

    def __init__(self) -> None:
        self.network_entries: dict[str, dict[str, Any]] = {}
        self.console_messages: list[dict[str, Any]] = []
        self.script_content_markers: set[str] = set()
        self.technology_versions: dict[str, str] = {}
        self._script_probe_tasks: list[asyncio.Task] = []
        self._primary_script_probes = 0
        self._reserved_script_bytes = 0

    def attach(self, page) -> None:
        page.on("request", self._on_request)
        page.on("response", self._on_response)
        page.on("requestfailed", self._on_request_failed)
        page.on("console", self._on_console)

    async def finish_script_probes(self) -> None:
        if self._script_probe_tasks:
            await asyncio.gather(*self._script_probe_tasks, return_exceptions=True)

    def _has_room_for(self, url: str) -> bool:
        return url in self.network_entries or len(self.network_entries) < MAX_NETWORK_ENTRIES

    async def _probe_script_response(self, response) -> None:
        try:
            headers = response.headers
            if not is_javascript_response(response.url, headers.get("content-type", "")):
                return

            declared_size = declared_script_size(headers)
            if declared_size is None:
                return
            if self._reserved_script_bytes + declared_size > MAX_TECHNOLOGY_SCRIPT_TOTAL_BYTES:
                return
            self._reserved_script_bytes += declared_size

            content = await asyncio.wait_for(response.body(), timeout=SCRIPT_BODY_TIMEOUT_SECONDS)
            if len(content) > declared_size or len(content) > MAX_TECHNOLOGY_SCRIPT_BYTES:
                return
            self.script_content_markers.update(script_content_markers(content))
            self.technology_versions.update(script_technology_versions(content))
        except Exception as exc:
            logger.debug("Could not inspect script fingerprint for %s: %s", response.url, exc)

    def _on_request(self, request) -> None:
        if not self._has_room_for(request.url):
            return
        self.network_entries[request.url] = {
            "url": request.url,
            "method": request.method,
            "resource_type": request.resource_type,
            "status": None,
            "failed": False,
            "failure": None,
        }

    def _on_response(self, response) -> None:
        if not self._has_room_for(response.url):
            return
        entry = self.network_entries.setdefault(response.url, {"url": response.url})
        entry.update(
            {
                "status": response.status,
                "resource_type": response.request.resource_type,
                "method": response.request.method,
                "failed": response.status >= 400,
                "content_type": response.headers.get("content-type", ""),
                "content_length": response.headers.get("content-length", ""),
                "server": response.headers.get("server", ""),
                "powered_by": response.headers.get("x-powered-by", ""),
            }
        )
        is_javascript = is_javascript_response(
            response.url, response.headers.get("content-type", "")
        )
        has_probe_capacity = len(self._script_probe_tasks) < MAX_TECHNOLOGY_SCRIPT_PROBES
        is_primary = is_primary_script_bundle(response.url)
        has_primary_capacity = is_primary and self._primary_script_probes < MAX_PRIMARY_SCRIPT_PROBES
        if is_javascript and (has_probe_capacity or has_primary_capacity):
            if not has_probe_capacity:
                self._primary_script_probes += 1
            task = asyncio.create_task(self._probe_script_response(response))
            self._script_probe_tasks.append(task)

    def _on_request_failed(self, request) -> None:
        if not self._has_room_for(request.url):
            return
        entry = self.network_entries.setdefault(request.url, {"url": request.url})
        failure = request.failure or ""
        entry.update(
            {
                "method": request.method,
                "resource_type": request.resource_type,
                "failed": True,
                "failure": failure,
            }
        )

    def _on_console(self, message) -> None:
        if len(self.console_messages) >= MAX_CONSOLE_MESSAGES:
            return
        self.console_messages.append(
            {
                "type": message.type,
                "text": message.text[:1000],
                "location": message.location,
            }
        )
