"""Writing an approved taxonomy draft to the library."""
from __future__ import annotations

from typing import Any

from fastapi import HTTPException
from sqlalchemy.orm import Session

from models.tag import BookmarkTag, Tag
from services.tag_colors import next_color
from services.taxonomy import drafts
from services.taxonomy.vocabulary import canonical_key, normalize_tag_name

# SQLite binds at most 32,766 parameters per statement.
ID_CHUNK_SIZE = 500


def apply_draft(db: Session, draft_id: str, edits: list[dict[str, Any]]) -> dict[str, Any]:
    """Replace the selection's AI tags with the reviewed draft, in one transaction.

    Manual tags are never removed; AI tags left without any bookmark are
    deleted afterwards.
    """
    draft = drafts.get_draft(draft_id)
    if not draft:
        raise HTTPException(404, "Taxonomy draft not found or expired")
    edit_by_id = {str(edit.get("id")): edit for edit in edits}
    selected_ids = {bookmark_id for tag in draft["tags"] for bookmark_id in tag["bookmark_ids"]}
    selected_ids.update(item["id"] for item in draft["untagged"])

    # A whole-library run can select more ids than SQLite binds per statement.
    # Chunk the IN lists; all chunks share this one transaction.
    ordered_ids = sorted(selected_ids)
    old_ai_tag_ids: set[str] = set()
    for start in range(0, len(ordered_ids), ID_CHUNK_SIZE):
        chunk = ordered_ids[start:start + ID_CHUNK_SIZE]
        old_ai_tag_ids.update(
            tag_id for (tag_id,) in db.query(BookmarkTag.tag_id).filter(
                BookmarkTag.bookmark_id.in_(chunk),
                BookmarkTag.source == "ai",
            ).all()
        )
        db.query(BookmarkTag).filter(
            BookmarkTag.bookmark_id.in_(chunk),
            BookmarkTag.source == "ai",
        ).delete(synchronize_session=False)

    assignments: set[tuple[str, str]] = set()
    applied_tag_ids: set[str] = set()
    existing_tags = db.query(Tag).all()
    existing_by_key = {canonical_key(tag.name): tag for tag in existing_tags}
    for draft_tag in draft["tags"]:
        edit = edit_by_id.get(draft_tag["id"], {})
        if edit.get("enabled", True) is False:
            continue
        name = normalize_tag_name(str(edit.get("name") or draft_tag["name"]))
        if not name:
            continue
        tag = existing_by_key.get(canonical_key(name))
        if not tag:
            tag = Tag(name=name, color=next_color(db), source="ai")
            db.add(tag)
            db.flush()
            existing_by_key[canonical_key(name)] = tag
        for bookmark_id in draft_tag["bookmark_ids"]:
            pair = (bookmark_id, tag.id)
            if pair in assignments:
                continue
            manual_exists = db.query(BookmarkTag).filter(
                BookmarkTag.bookmark_id == bookmark_id,
                BookmarkTag.tag_id == tag.id,
            ).first()
            if not manual_exists:
                db.add(BookmarkTag(bookmark_id=bookmark_id, tag_id=tag.id, source="ai"))
            assignments.add(pair)
        applied_tag_ids.add(tag.id)

    db.flush()
    for tag_id in old_ai_tag_ids:
        tag = db.get(Tag, tag_id)
        remaining = db.query(BookmarkTag).filter(BookmarkTag.tag_id == tag_id).count()
        if tag and tag.source == "ai" and remaining == 0:
            db.delete(tag)
    db.commit()
    drafts.discard_draft(draft_id)
    assigned_bookmarks = len({bookmark_id for bookmark_id, _ in assignments})
    return {
        "status": "ok",
        "tags": len(applied_tag_ids),
        "assignments": len(assignments),
        "assigned": assigned_bookmarks,
        "without_tags": draft["total"] - assigned_bookmarks,
        "total": draft["total"],
    }
