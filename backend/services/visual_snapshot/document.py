"""Builds the snapshot document that is stored and returned to the app.

The shape is a contract with Gyrus/Models/VisualSnapshotDTOs.swift
(VisualSnapshotDTO, VisualViewportDTO, VisualSiteStructureDTO, ...). Adding
keys is safe; renaming or removing one breaks decoding in the app. Everything
here is pure: inputs in, dictionaries out.
"""

from datetime import datetime, timezone
from typing import Any

from services.visual_snapshot.analysis.network import (
    document_response_headers,
    network_summary,
)
from services.visual_snapshot.analysis.technologies import (
    detect_technologies,
    enrich_technology_signals,
)
from services.visual_snapshot.config import SNAPSHOT_SCHEMA_VERSION

MAX_STORED_CONSOLE_MESSAGES = 60
MAX_ERROR_MESSAGE_CHARS = 1000


def new_snapshot(
    bookmark_id: str,
    run_id: str,
    url: str,
    title: str,
    *,
    captured_at: datetime | None = None,
) -> dict[str, Any]:
    return {
        "bookmark_id": bookmark_id,
        "schema_version": SNAPSHOT_SCHEMA_VERSION,
        "run_id": run_id,
        "url": url,
        "title": title,
        "captured_at": (captured_at or datetime.now(timezone.utc)).isoformat(),
        "status": "running",
        "navigation": [],
        "site_structure": None,
        "viewports": [],
        "errors": [],
    }


def assemble_viewport(
    extracted: dict[str, Any],
    technology_signals: dict[str, Any] | None,
    viewport: dict[str, Any],
    *,
    screenshot_name: str,
    screenshot_url: str,
    screenshot_truncated: bool,
    dominant_colors: list[str],
    network_entries: dict[str, dict[str, Any]],
    console_messages: list[dict[str, Any]],
    script_content_markers: set[str] | list[str],
    technology_versions: dict[str, str],
) -> dict[str, Any]:
    """Turn one viewport's extraction plus browser observations into a document.

    ``extracted`` is the extractor result after extraction.split_extraction;
    it is extended in place so the extractor's key order is kept.
    """
    signals = enrich_technology_signals(
        technology_signals,
        script_markers=script_content_markers,
        technology_versions=technology_versions,
        response_headers=document_response_headers(network_entries),
    )
    extracted["technologies"] = detect_technologies(signals)
    extracted.update(
        {
            "name": viewport["name"],
            "width": viewport["width"],
            "height": viewport["height"],
            "screenshot": screenshot_name,
            "screenshot_truncated": screenshot_truncated,
            "screenshot_url": screenshot_url,
            "dominant_colors": dominant_colors,
            "network": network_summary(network_entries),
            "console_messages": console_messages[:MAX_STORED_CONSOLE_MESSAGES],
        }
    )
    return extracted


def viewport_error(viewport: dict[str, Any], error: BaseException) -> dict[str, Any]:
    """VisualSnapshotErrorDTO: why one viewport is missing."""
    return {"viewport": viewport["name"], "message": str(error)[:MAX_ERROR_MESSAGE_CHARS]}


def site_structure_failure(url: str, error: BaseException) -> dict[str, Any]:
    """An empty VisualSiteStructureDTO that carries the crawl error."""
    return {
        "origin": url,
        "listed_page_count": 0,
        "sitemap_page_count": 0,
        "crawled_page_count": 0,
        "pages": [],
        "page_tree": [],
        "sitemap_sources": [],
        "errors": [str(error)[:MAX_ERROR_MESSAGE_CHARS]],
    }


def capture_status(snapshot: dict[str, Any]) -> str:
    """Return failed (no viewport), partial (some viewports threw) or completed."""
    if not snapshot["viewports"]:
        return "failed"
    return "partial" if snapshot["errors"] else "completed"
