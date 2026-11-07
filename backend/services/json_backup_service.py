"""Portable JSON backup of the whole library: export, validation, restore.

This is the document behind GET /api/data/backup and POST /api/data/restore
(the app's "Export / Restore backup"). It is separate from
services/backup_service.py, which keeps automatic copies of the database file.
Restore validates the complete document (RestoreData) before the destructive
transaction starts, and only touches derived data (vectors, Brain mirror,
cached files) after that transaction committed.
"""
import logging
from datetime import datetime, timezone

from fastapi import HTTPException
from pydantic import BaseModel, Field, model_validator, ConfigDict
from sqlalchemy.orm import Session

from models.bookmark import Bookmark, BookmarkNote, BrainMessage
from models.collection import Collection
from models.tag import Tag, BookmarkTag
from services import ai_policy, bookmark_service
from services.brain_sync_service import brain_sync_service

logger = logging.getLogger(__name__)

BACKUP_VERSION = 2
SUPPORTED_BACKUP_VERSIONS = {1, BACKUP_VERSION}


def _iso(dt: datetime | None) -> str | None:
    return dt.isoformat() if dt else None


def _parse_dt(value: str | None) -> datetime:
    if value:
        try:
            return datetime.fromisoformat(value)
        except ValueError:
            pass
    return datetime.now(timezone.utc)


def _parse_optional_dt(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def export_library(db: Session) -> dict:
    """Everything as one JSON-serializable document."""
    return {
        "version": BACKUP_VERSION,
        "exported_at": datetime.now(timezone.utc).isoformat(),
        "collections": [
            {
                "id": c.id, "name": c.name, "icon": c.icon, "color": c.color,
                "parent_id": c.parent_id, "position": c.position,
                "created_at": _iso(c.created_at),
            }
            for c in db.query(Collection).all()
        ],
        "tags": [
            {
                "id": t.id, "name": t.name, "color": t.color,
                "source": t.source, "created_at": _iso(t.created_at),
            }
            for t in db.query(Tag).all()
        ],
        "bookmarks": [
            {
                "id": b.id, "title": b.title, "url": b.url,
                "description": b.description, "notes": b.notes,
                "favicon_path": b.favicon_path, "og_image_url": b.og_image_url,
                "og_image_path": b.og_image_path, "source": b.source,
                "is_dead": b.is_dead, "is_read": b.is_read,
                "scraped_content": b.scraped_content,
                "metadata_status": b.metadata_status,
                "reader_status": b.reader_status,
                "index_status": b.index_status,
                "analysis_error": b.analysis_error,
                "analysis_attempts": b.analysis_attempts,
                "analysis_updated_at": _iso(b.analysis_updated_at),
                "deleted_at": _iso(b.deleted_at),
                "collection_id": b.collection_id,
                "created_at": _iso(b.created_at), "updated_at": _iso(b.updated_at),
            }
            for b in db.query(Bookmark).all()
        ],
        "bookmark_notes": [
            {
                "id": n.id, "bookmark_id": n.bookmark_id, "content": n.content,
                "source": n.source, "created_at": _iso(n.created_at), "updated_at": _iso(n.updated_at),
            }
            for n in db.query(BookmarkNote).all()
        ],
        "brain_messages": [
            {
                "id": m.id, "bookmark_id": m.bookmark_id, "role": m.role,
                "content": m.content, "model": m.model, "status": m.status,
                "created_at": _iso(m.created_at),
            }
            for m in db.query(BrainMessage).all()
        ],
        "bookmark_tags": [
            {
                "bookmark_id": bt.bookmark_id,
                "tag_id": bt.tag_id,
                "source": bt.source,
            }
            for bt in db.query(BookmarkTag).all()
        ],
    }


class RestoreData(BaseModel):
    model_config = ConfigDict(extra="forbid")
    version: int = Field(strict=True)
    exported_at: datetime | None = None
    collections: list[dict] = Field(max_length=100_000)
    tags: list[dict] = Field(max_length=100_000)
    bookmarks: list[dict] = Field(max_length=250_000)
    bookmark_notes: list[dict] = Field(default_factory=list, max_length=500_000)
    brain_messages: list[dict] = Field(default_factory=list, max_length=1_000_000)
    bookmark_tags: list[dict] = Field(default_factory=list, max_length=1_000_000)


    @model_validator(mode="after")
    def validate_backup(self):
        if self.version not in SUPPORTED_BACKUP_VERSIONS:
            raise ValueError("Unsupported backup version")
        # Validate all relationships before the destructive transaction starts.
        import re
        tables = ("collections", "tags", "bookmarks", "bookmark_notes", "brain_messages")
        indexes = {}
        for table in tables:
            rows = getattr(self, table)
            index = {}
            for row in rows:
                ident = row.get("id")
                if not isinstance(ident, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", ident):
                    raise ValueError(f"Invalid {table} id")
                if ident in index:
                    raise ValueError(f"Duplicate {table} id")
                index[ident] = row
                required_text = {
                    "collections": ("name",), "tags": ("name",), "bookmarks": ("url",),
                    "bookmark_notes": ("bookmark_id",), "brain_messages": ("bookmark_id",)
                }
                for key in required_text[table]:
                    if not isinstance(row.get(key), str) or (not row[key].strip() and table != "collections"):
                        raise ValueError(f"Missing {table}.{key}")
                nonnull_text = {"title", "source", "content", "role", "status", "metadata_status", "reader_status", "index_status"}
                if any(key in row and not isinstance(row[key], str) for key in nonnull_text):
                    raise ValueError(f"Invalid required text in {table}")
                for key, value in row.items():
                    if key in {"is_dead", "is_read"}:
                        if not isinstance(value, bool):
                            raise ValueError(f"Invalid boolean: {key}")
                    elif key in {"position", "analysis_attempts"}:
                        if type(value) is not int or value < 0:
                            raise ValueError(f"Invalid integer: {key}")
                    elif value is not None and not isinstance(value, str):
                        raise ValueError(f"Invalid text: {key}")
                    if key.endswith("_at") and value is not None:
                        try:
                            datetime.fromisoformat(value)
                        except (ValueError, TypeError):
                            raise ValueError(f"Invalid date: {key}") from None
            indexes[table] = index
        sibling_names = set()
        children = {}
        for row in self.collections:
            name, parent = row.get("name"), row.get("parent_id")
            # Legacy Gyrus allowed blank/long names. Preserve them in backups;
            # stricter limits apply to new edits, not already-owned text.
            if not isinstance(name, str):
                raise ValueError("Invalid collection name")
            if parent is not None and parent not in indexes["collections"]:
                raise ValueError("Unknown collection parent")
            key = (parent, name)
            if key in sibling_names:
                raise ValueError("Duplicate collection name in the same folder")
            sibling_names.add(key)
            children.setdefault(parent, []).append(row)
        ordered = list(children.get(None, []))
        depths = {row["id"]: 1 for row in ordered}
        for row in ordered:
            # Older libraries could exceed the new 64-level editing limit.
            # Sorting and validation are iterative, preserving that hierarchy.
            descendants = children.get(row["id"], [])
            depths.update({child["id"]: depths[row["id"]] + 1 for child in descendants})
            ordered.extend(descendants)
        if len(ordered) != len(self.collections):
            raise ValueError("Collection hierarchy contains a cycle")
        self.collections = ordered
        names = set()
        for row in self.tags:
            name = row.get("name")
            if not isinstance(name, str) or not name.strip() or name in names:
                raise ValueError("Invalid or duplicate tag name")
            names.add(name)
        urls = set()
        from urllib.parse import urlsplit
        for row in self.bookmarks:
            url = row.get("url")
            if not isinstance(url, str) or len(url) > 8192:
                raise ValueError("Invalid bookmark URL")
            parsed = urlsplit(url)
            if parsed.scheme not in {"http", "https"} or not parsed.hostname or url in urls:
                raise ValueError("Invalid or duplicate bookmark URL")
            urls.add(url)
            if row.get("collection_id") is not None and row["collection_id"] not in indexes["collections"]:
                raise ValueError("Unknown bookmark collection")
        for row in self.bookmark_notes + self.brain_messages:
            if row.get("bookmark_id") not in indexes["bookmarks"]:
                raise ValueError("Unknown note/message bookmark")
        links = set()
        for row in self.bookmark_tags:
            if not isinstance(row.get("bookmark_id"), str) or not isinstance(row.get("tag_id"), str):
                raise ValueError("Invalid bookmark tag reference")
            key = (row.get("bookmark_id"), row.get("tag_id"))
            if key[0] not in indexes["bookmarks"] or key[1] not in indexes["tags"] or key in links:
                raise ValueError("Invalid or duplicate bookmark tag link")
            if not isinstance(row.get("source", "manual"), str):
                raise ValueError("Invalid tag source")
            links.add(key)
        return self


def restore_library(db: Session, data: RestoreData) -> None:
    """Replace ALL current data with a validated backup document."""
    previous_ids = [row.id for row in db.query(Bookmark.id).all()]
    try:
        # 1. Wipe existing data (FK-safe order).
        from services import vector_store
        vector_store.invalidate_for_replacement(db)
        db.query(BookmarkTag).delete()
        db.query(BrainMessage).delete()
        db.query(BookmarkNote).delete()
        db.query(Bookmark).delete()
        db.query(Collection).delete()
        db.query(Tag).delete()
        db.flush()

        # 2. Tags.
        for t in data.tags:
            db.add(Tag(id=t["id"], name=t["name"], color=t.get("color"),
                       source=t.get("source", "manual"),
                       created_at=_parse_dt(t.get("created_at"))))

        # Parents precede children; names remain scoped to their actual parent.
        for c in data.collections:
            db.add(Collection(id=c["id"], name=c["name"], icon=c.get("icon"),
                              color=c.get("color"), parent_id=c.get("parent_id"),
                              position=c.get("position", 0), created_at=_parse_dt(c.get("created_at"))))
            db.flush()

        # 4. Bookmarks.
        for b in data.bookmarks:
            db.add(Bookmark(
                id=b["id"], title=b.get("title", ""), url=b["url"],
                description=b.get("description"), notes=b.get("notes"),
                favicon_path=None, og_image_url=b.get("og_image_url"),
                og_image_path=None, source=b.get("source", "manual"),
                is_dead=b.get("is_dead", False), is_read=b.get("is_read", False),
                scraped_content=b.get("scraped_content"),
                # favicon/og image files are not part of a backup and the
                # paths are cleared here, so metadata must be fetched again.
                # Keeping a restored "ready" meant icons never came back.
                # Trashed rows keep their state: nothing enriches them, and
                # the app refetches a missing icon lazily once restored.
                metadata_status=(
                    b.get("metadata_status", "pending") if b.get("deleted_at") else "pending"
                ),
                reader_status=b.get(
                    "reader_status",
                    "ready" if b.get("scraped_content") else "pending",
                ),
                index_status="pending" if ai_policy.enabled() and b.get("scraped_content") and not b.get("deleted_at") else "not_requested",
                analysis_error=b.get("analysis_error"),
                analysis_attempts=b.get("analysis_attempts", 0),
                analysis_updated_at=_parse_optional_dt(b.get("analysis_updated_at")),
                deleted_at=_parse_optional_dt(b.get("deleted_at")),
                collection_id=b.get("collection_id"),
                created_at=_parse_dt(b.get("created_at")), updated_at=_parse_dt(b.get("updated_at")),
            ))
        db.flush()

        # 5. Notes + tag links.
        for n in data.bookmark_notes:
            db.add(BookmarkNote(id=n["id"], bookmark_id=n["bookmark_id"],
                                content=n.get("content", ""), source=n.get("source", "user"),
                                created_at=_parse_dt(n.get("created_at")),
                                updated_at=_parse_dt(n.get("updated_at"))))
        for m in data.brain_messages:
            db.add(BrainMessage(id=m["id"], bookmark_id=m["bookmark_id"],
                                role=m.get("role", "assistant"),
                                content=m.get("content", ""),
                                model=m.get("model"),
                                status=m.get("status", "complete"),
                                created_at=_parse_dt(m.get("created_at"))))
        for bt in data.bookmark_tags:
            db.add(BookmarkTag(
                bookmark_id=bt["bookmark_id"],
                tag_id=bt["tag_id"],
                source=bt.get("source", "manual"),
            ))

        db.commit()
    except Exception as e:
        db.rollback()
        logger.exception("Backup restore failed")
        raise HTTPException(status_code=400, detail="Restore failed; the backup was not applied") from e

    # Only invalidate derived vectors after a successful data transaction.
    vector_store.clear()
    from services import bookmark_enrichment_service
    # Refetch favicons/preview images through the normal bounded pipeline.
    # Reader extraction is not re-run for rows whose reader stage is not
    # pending, so this never becomes a crawl of every page.
    for bookmark in data.bookmarks:
        if not bookmark.get("deleted_at"):
            bookmark_enrichment_service.schedule_enrichment(bookmark["id"])
    if ai_policy.enabled():
        for bookmark in data.bookmarks:
            if bookmark.get("scraped_content") and not bookmark.get("deleted_at"):
                bookmark_enrichment_service.schedule_index(bookmark["id"], bookmark["scraped_content"])
    bookmark_service.delete_generated_artifacts(list(set(previous_ids) | {b["id"] for b in data.bookmarks}))
    try:
        brain_sync_service.resync_all(db)
    except Exception:
        logger.exception("Backup restored, but Brain mirror could not be refreshed")
