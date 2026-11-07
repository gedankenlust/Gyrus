"""Validating a taxonomy into a reviewable draft, and keeping drafts for review.

The draft dictionary is returned to the app as-is, so its keys are a
contract: id, language, total, assigned, without_tags, tags[{id, name,
bookmark_ids, bookmark_titles, bookmark_count}], untagged[{id, title}] and,
from generate_draft, omitted_tags.
"""
from __future__ import annotations

import math
import uuid
from collections import defaultdict
from typing import Any

from models.bookmark import Bookmark
from services.taxonomy.errors import TaxonomyQualityError
from services.taxonomy.prompting import json_payload
from services.taxonomy.vocabulary import MAX_TAGS_PER_BOOKMARK, canonical_key, normalize_tag_name

# Drafts wait in memory until the user applies or discards them. Only the
# newest few are kept; an old review screen then reports "expired".
MAX_KEPT_DRAFTS = 3
_drafts: dict[str, dict[str, Any]] = {}


def remember_draft(draft: dict[str, Any]) -> None:
    _drafts[draft["id"]] = draft
    while len(_drafts) > MAX_KEPT_DRAFTS:
        _drafts.pop(next(iter(_drafts)))


def get_draft(draft_id: str) -> dict[str, Any] | None:
    return _drafts.get(draft_id)


def discard_draft(draft_id: str) -> None:
    _drafts.pop(draft_id, None)


def max_category_size(bookmark_count: int) -> int:
    if bookmark_count < 50:
        return max(8, math.ceil(bookmark_count * 0.45))
    return max(12, math.ceil(bookmark_count * 0.35))


def minimum_reusable_groups(bookmark_count: int, max_tags: int) -> int:
    if bookmark_count >= 50:
        return 3
    return min(3, max(2, max_tags // 4))


def parse_taxonomy(raw: str, keyed: dict[str, Bookmark], max_tags: int,
                   singleton_limit: int, language: str | None) -> dict[str, Any]:
    payload = json_payload(raw)
    items = payload.get("taxonomy") or payload.get("tags")
    if not isinstance(items, list):
        raise TaxonomyQualityError("The model response contains no taxonomy list.")

    grouped: dict[str, dict[str, Any]] = {}
    per_bookmark: dict[str, int] = defaultdict(int)
    for item in items:
        if not isinstance(item, dict):
            continue
        name = normalize_tag_name(str(item.get("name", "")))
        ids = item.get("bookmark_ids") or item.get("bookmarks") or []
        if not name or not isinstance(ids, list):
            continue
        canonical = canonical_key(name)
        group = grouped.setdefault(canonical, {"name": name, "bookmark_keys": []})
        for bookmark_key in ids:
            bookmark_key = str(bookmark_key).upper()
            if bookmark_key not in keyed or per_bookmark[bookmark_key] >= MAX_TAGS_PER_BOOKMARK:
                continue
            if bookmark_key not in group["bookmark_keys"]:
                group["bookmark_keys"].append(bookmark_key)
                per_bookmark[bookmark_key] += 1

    groups = [group for group in grouped.values() if group["bookmark_keys"]]
    groups.sort(key=lambda group: (-len(group["bookmark_keys"]), group["name"]))
    assigned_keys = {key for group in groups for key in group["bookmark_keys"]}
    singleton_count = sum(len(group["bookmark_keys"]) == 1 for group in groups)
    # A sparse but trustworthy taxonomy is more useful than forcing unrelated
    # long-tail bookmarks into plausible-sounding categories.
    minimum_assigned = max(1, math.ceil(len(keyed) * 0.20))
    minimum_groups = minimum_reusable_groups(len(keyed), max_tags)
    issues: list[str] = []
    if len(groups) > max_tags:
        issues.append(f"{len(groups)} tags exceed the limit of {max_tags}")
    if len(keyed) >= 10 and len(groups) < minimum_groups:
        issues.append(f"only {len(groups)} reusable tags were produced; at least {minimum_groups} are needed")
    if len(keyed) >= 10 and singleton_count > singleton_limit:
        issues.append(f"{singleton_count} one-off tags exceed the limit of {singleton_limit}")
    oversized = [
        f"{group['name']} ({len(group['bookmark_keys'])})"
        for group in groups
        if len(group["bookmark_keys"]) > max_category_size(len(keyed))
    ]
    if oversized:
        issues.append(
            "oversized catch-all categories: " + ", ".join(oversized[:3])
        )
    if len(assigned_keys) < minimum_assigned:
        issues.append(f"only {len(assigned_keys)} of {len(keyed)} bookmarks are assigned")
    if issues:
        raise TaxonomyQualityError("; ".join(issues))

    draft_tags: list[dict[str, Any]] = []
    for index, group in enumerate(groups, 1):
        bookmarks = [keyed[key] for key in group["bookmark_keys"]]
        draft_tags.append({
            "id": f"T{index:03d}",
            "name": group["name"],
            "bookmark_ids": [bookmark.id for bookmark in bookmarks],
            "bookmark_titles": [bookmark.title for bookmark in bookmarks],
            "bookmark_count": len(bookmarks),
        })

    untagged = [
        {"id": bookmark.id, "title": bookmark.title}
        for key, bookmark in keyed.items() if key not in assigned_keys
    ]
    return {
        "id": str(uuid.uuid4()),
        "language": language or "en",
        "total": len(keyed),
        "assigned": len(assigned_keys),
        "without_tags": len(untagged),
        "tags": draft_tags,
        "untagged": untagged,
    }
