"""Summaries of the requests a viewport made while it rendered."""

from collections import Counter
from typing import Any

LARGE_REQUEST_BYTES = 250_000
MAX_LISTED_REQUESTS = 30


def network_item(item: dict[str, Any]) -> dict[str, Any]:
    return {
        "url": item.get("url", ""),
        "method": item.get("method", ""),
        "resource_type": item.get("resource_type", ""),
        "status": item.get("status"),
        "content_type": item.get("content_type", ""),
        "failure": item.get("failure", ""),
    }


def network_summary(entries: dict[str, dict[str, Any]]) -> dict[str, Any]:
    resources = list(entries.values())
    counts: Counter[str] = Counter()
    failed: list[dict[str, Any]] = []
    large: list[dict[str, Any]] = []

    for item in resources:
        resource_type = item.get("resource_type") or "other"
        counts[resource_type] += 1

        if item.get("failed") or (item.get("status") and item["status"] >= 400):
            failed.append(network_item(item))

        try:
            size = int(item.get("content_length") or 0)
        except Exception:
            size = 0
        if size >= LARGE_REQUEST_BYTES:
            large_item = network_item(item)
            large_item["content_length"] = size
            large.append(large_item)

    return {
        "request_count": len(resources),
        "resource_counts": [
            {"type": kind, "count": count}
            for kind, count in sorted(counts.items(), key=lambda pair: (-pair[1], pair[0]))
        ],
        "failed_requests": failed[:MAX_LISTED_REQUESTS],
        "large_requests": sorted(
            large, key=lambda item: item.get("content_length", 0), reverse=True
        )[:MAX_LISTED_REQUESTS],
    }


def document_response_headers(entries: dict[str, dict[str, Any]]) -> list[str]:
    """Server identification headers of document responses, de-duplicated.

    Only documents count: a CDN serving a third-party script says nothing
    about how the site itself is hosted.
    """
    headers: list[str] = []
    for entry in entries.values():
        if entry.get("resource_type") != "document":
            continue
        if entry.get("server"):
            headers.append(f"Server: {entry['server']}")
        if entry.get("powered_by"):
            headers.append(f"X-Powered-By: {entry['powered_by']}")
    return list(dict.fromkeys(headers))
