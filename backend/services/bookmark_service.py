"""Bookmark lifecycle: create (or restore from Trash), update, move, mark
read, trash, restore, purge, notes and cached page text.

This module is also the stable facade for the bookmark services: the read-only
queries (bookmark_query_service), the derived-data upkeep
(bookmark_derived_data) and AI tagging (bookmark_auto_tag_service) are
re-exported here, so `bookmark_service.<name>` keeps working for every caller.
Lifecycle functions call the derived-data helpers through this module's
namespace, which is what lets tests patch e.g. `bookmark_service._drop_vectors`.
"""
import asyncio
import logging
from datetime import datetime, timezone, timedelta
from sqlalchemy.orm import Session
from sqlalchemy.exc import IntegrityError
from models.bookmark import Bookmark
from models.collection import Collection
from models.tag import Tag, BookmarkTag
from schemas.bookmark import BookmarkCreate, BookmarkUpdate
from services.brain_sync_service import brain_sync_service
from services.bookmark_query_service import (  # noqa: F401 — re-exported
    ID_CHUNK_SIZE,
    _SORT_COLUMNS,
    _chunks,
    count_trashed,
    get_bookmark,
    get_bookmarks,
    get_trashed,
)
from services.bookmark_derived_data import (  # noqa: F401 — re-exported
    _drop_vectors,
    _safe_brain_sync,
    delete_generated_artifacts,
    index_bookmark_embedding,
)
from services.bookmark_auto_tag_service import auto_tag_bookmark  # noqa: F401 — re-exported

logger = logging.getLogger(__name__)

# How long a bookmark stays recoverable in the Trash before it is purged.
TRASH_RETENTION_DAYS = 30


def create_bookmark(db: Session, data: BookmarkCreate) -> Bookmark:
    return create_or_restore_bookmark(db, data)[0]


def create_or_restore_bookmark(db: Session, data: BookmarkCreate) -> tuple[Bookmark, bool]:
    """Create a bookmark; returns (bookmark, restored_from_trash)."""
    from services.url_utils import normalize_url
    url = normalize_url(data.url)

    # Check for duplicates (against the normalized URL)
    found = db.query(Bookmark).filter(Bookmark.url == url).first()
    if found and found.deleted_at is None:
        from fastapi import HTTPException
        raise HTTPException(status_code=409, detail="Bookmark already exists")

    _require_references(db, data.collection_id, data.tag_ids)
    collection_id = data.collection_id

    # Extension / menu-bar quick-add: automatic Inbox assignment
    if data.source in ("extension", "menubar") and not collection_id:
        inbox = db.query(Collection).filter(Collection.name == "Inbox", Collection.parent_id == None).first()
        if not inbox:
            try:
                # Use a separate subtransaction-like approach (flush + catch)
                inbox = Collection(name="Inbox")
                db.add(inbox)
                db.flush()
            except IntegrityError:
                db.rollback()
                # If another request created it in the meantime, fetch it
                inbox = db.query(Collection).filter(Collection.name == "Inbox", Collection.parent_id == None).one()
        collection_id = inbox.id

    if found is not None:
        # The URL only exists in the Trash. Saving it again is an explicit
        # "I want this bookmark", so bring the trashed row back instead of
        # refusing with 409 (the extension showed "already saved" for a
        # bookmark the user could not see) — and keep its Reader text,
        # notes and analysis.
        return _restore_trashed_as_created(db, found, data, collection_id), True

    bm = Bookmark(
        title=data.title,
        url=url,
        description=data.description,
        notes=data.notes,
        collection_id=collection_id,
        source=data.source,
    )
    db.add(bm)
    db.flush()
    _set_tags(db, bm, data.tag_ids)
    db.commit()
    db.refresh(bm)
    
    # Sync with AI Brain (best-effort — never block the save)
    _safe_brain_sync(lambda: brain_sync_service.sync_bookmark(db, bm))
    _safe_brain_sync(lambda: brain_sync_service.rebuild_index(db))

    return bm, False


def _restore_trashed_as_created(
    db: Session, bm: Bookmark, data: BookmarkCreate, collection_id: str | None
) -> Bookmark:
    """Apply a create request to a trashed row with the same URL."""
    bm.deleted_at = None
    bm.title = data.title
    if data.description is not None:
        bm.description = data.description
    if data.notes is not None:
        bm.notes = data.notes
    # An explicit folder (or the extension's Inbox) wins; otherwise the
    # bookmark returns to where it was before it was trashed.
    if collection_id is not None:
        bm.collection_id = collection_id
    if data.tag_ids:
        _set_tags(db, bm, data.tag_ids)
    db.commit()
    db.expire(bm, ["bookmark_tags"])
    db.refresh(bm)

    # Trashing removed the Brain mirror and the vector. The mirror is rebuilt
    # here like a fresh create; the enrichment scheduled by the caller
    # re-indexes the kept Reader text.
    _safe_brain_sync(lambda: brain_sync_service.sync_bookmark(db, bm))
    _safe_brain_sync(lambda: brain_sync_service.rebuild_index(db))
    return bm


def _require_references(
    db: Session, collection_id: str | None, tag_ids: list[str] | None
) -> None:
    """Reject unknown folder/tag ids before the write.

    Otherwise SQLite's foreign-key check fails at flush/commit and surfaces as
    a misleading 409 "already exists" (create) or a 500 (update).
    """
    from fastapi import HTTPException
    if collection_id is not None and db.get(Collection, collection_id) is None:
        raise HTTPException(status_code=422, detail="Collection not found")
    if tag_ids:
        wanted = list(dict.fromkeys(tag_ids))
        found = set()
        for chunk in _chunks(wanted):
            found.update(
                tag_id for (tag_id,) in db.query(Tag.id).filter(Tag.id.in_(chunk)).all()
            )
        if len(found) != len(wanted):
            raise HTTPException(status_code=422, detail="One or more tags were not found")


def update_bookmark(db: Session, bm: Bookmark, data: BookmarkUpdate) -> Bookmark:
    _require_references(
        db,
        data.collection_id if "collection_id" in data.model_fields_set else None,
        data.tag_ids,
    )
    if data.url is not None:
        from services.url_utils import normalize_url
        data = data.model_copy(update={"url": normalize_url(data.url)})
    url_changed = data.url is not None and data.url != bm.url
    if url_changed and db.query(Bookmark.id).filter(Bookmark.url == data.url, Bookmark.id != bm.id).first():
        from fastapi import HTTPException
        raise HTTPException(409, "Bookmark already exists")
    if url_changed:
        from services.maintenance import reserve
        reserve()
    # Capture old path to handle renames/moves
    try:
        old_path = brain_sync_service._get_bookmark_file_path(db, bm)
    except Exception:
        old_path = None

    changed = data.model_dump(exclude_unset=True, exclude={"tag_ids"})
    for field, value in changed.items():
        setattr(bm, field, value)
    if data.tag_ids is not None:
        _set_tags(db, bm, data.tag_ids)
    if url_changed:
        bm.scraped_content = None
        bm.favicon_path = None
        bm.og_image_url = None
        bm.og_image_path = None
        bm.is_dead = False
        bm.metadata_status = "pending"
        bm.reader_status = "pending"
        bm.index_status = "not_requested"
        bm.analysis_error = None
        bm.analysis_attempts = 0
        bm.analysis_updated_at = None
    db.commit()
    db.refresh(bm)
    if url_changed:
        _drop_vectors([bm.id])
        delete_generated_artifacts([bm.id])
        # Keep externally added text in a separate, unowned archive of the old URL.
        def archive_previous_mirror():
            if old_path and brain_sync_service._owns(old_path, bm.id):
                import uuid
                archived = old_path.with_name(f"previous-url-{uuid.uuid4()}.md")
                text = old_path.read_text(encoding="utf-8").replace(
                    "\ngyrus_bookmark_id:", "\nprevious_gyrus_bookmark_id:", 1)
                with archived.open("x", encoding="utf-8") as handle:
                    handle.write(text)
                old_path.unlink()
        _safe_brain_sync(archive_previous_mirror)
        old_path = None
        from services import bookmark_enrichment_service
        bookmark_enrichment_service.schedule_enrichment(bm.id)

    # Sync with AI Brain (best-effort — never block the update)
    _safe_brain_sync(lambda: brain_sync_service.sync_bookmark(db, bm, old_path=old_path))
    _safe_brain_sync(lambda: brain_sync_service.rebuild_index(db))

    # Re-embed when text the vector is built from changed, so semantic search
    # doesn't keep ranking by the old content. Same text selection as reindex:
    # scraped content if present, else title + description.
    if not url_changed and changed.keys() & {"title", "description", "notes", "scraped_content"}:
        text = bm.scraped_content or f"{bm.title or ''} {bm.description or ''}".strip()
        if text:
            from services import background
            background.schedule(index_bookmark_embedding(bm.id, text))

    return bm


def move_bookmarks(
    db: Session, ids: list[str], collection_id: str | None
) -> int:
    """Move an entire selection atomically and refresh the Brain mirror once."""
    unique_ids = list(dict.fromkeys(ids))
    if collection_id is not None and db.get(Collection, collection_id) is None:
        raise LookupError("Collection not found")

    bookmarks = db.query(Bookmark).filter(
        Bookmark.id.in_(unique_ids), Bookmark.deleted_at.is_(None)
    ).all()
    if len(bookmarks) != len(unique_ids):
        raise LookupError("One or more bookmarks were not found")

    old_paths = {}
    for bookmark in bookmarks:
        try:
            old_paths[bookmark.id] = brain_sync_service._get_bookmark_file_path(db, bookmark)
        except Exception:
            old_paths[bookmark.id] = None
        bookmark.collection_id = collection_id

    db.commit()
    for bookmark in bookmarks:
        _safe_brain_sync(
            lambda bookmark=bookmark: brain_sync_service.sync_bookmark(
                db, bookmark, old_path=old_paths[bookmark.id]
            )
        )
    _safe_brain_sync(lambda: brain_sync_service.rebuild_index(db))
    return len(bookmarks)


def set_bookmarks_read(db: Session, ids: list[str], is_read: bool) -> int:
    """Set read state for a complete selection in one transaction."""
    unique_ids = list(dict.fromkeys(ids))
    bookmarks = db.query(Bookmark).filter(
        Bookmark.id.in_(unique_ids), Bookmark.deleted_at.is_(None)
    ).all()
    if len(bookmarks) != len(unique_ids):
        raise LookupError("One or more bookmarks were not found")

    for bookmark in bookmarks:
        bookmark.is_read = is_read
    db.commit()
    return len(bookmarks)


def delete_bookmark(db: Session, bm: Bookmark) -> None:
    """Soft-delete: move the bookmark to the Trash. Its AI-Brain markdown file is
    removed so it disappears from the mirror, but the row is kept (recoverable)
    until it is purged."""
    db_session = Session.object_session(bm)
    _safe_brain_sync(lambda: brain_sync_service.delete_bookmark_file(db_session, bm))
    # Remove from vector index so it no longer appears in semantic search.
    try:
        from services import vector_store
        vector_store.delete(bm.id)
    except Exception as exc:
        logger.warning("Vector removal failed for bookmark %s: %s", bm.id, exc)

    bm.deleted_at = datetime.now(timezone.utc)
    db.commit()
    _safe_brain_sync(lambda: brain_sync_service.rebuild_index(db))


def delete_bookmarks(db: Session, ids: list[str]) -> None:
    """Soft-delete multiple bookmarks (move them to the Trash)."""
    unique_ids = list(dict.fromkeys(ids))
    # Best-effort: remove the brain markdown files (only for ones not already trashed).
    bms = []
    for chunk in _chunks(unique_ids):
        bms.extend(db.query(Bookmark).filter(
            Bookmark.id.in_(chunk), Bookmark.deleted_at.is_(None)
        ).all())
    _safe_brain_sync(lambda: brain_sync_service.delete_bookmarks_files(db, bms))
    _drop_vectors([bm.id for bm in bms])

    # All chunks share one transaction, so a selection is trashed entirely or
    # not at all.
    deleted_at = datetime.now(timezone.utc)
    for chunk in _chunks([bm.id for bm in bms]):
        db.query(Bookmark).filter(
            Bookmark.id.in_(chunk), Bookmark.deleted_at.is_(None)
        ).update({Bookmark.deleted_at: deleted_at}, synchronize_session=False)
    db.commit()
    _safe_brain_sync(lambda: brain_sync_service.rebuild_index(db))


def restore_bookmarks(db: Session, ids: list[str]) -> int:
    """Bring bookmarks back from the Trash and recreate their brain files."""
    bms = []
    for chunk in _chunks(list(dict.fromkeys(ids))):
        bms.extend(db.query(Bookmark).filter(
            Bookmark.id.in_(chunk), Bookmark.deleted_at.is_not(None)
        ).all())
    if not bms:
        return 0

    for chunk in _chunks([bm.id for bm in bms]):
        db.query(Bookmark).filter(
            Bookmark.id.in_(chunk), Bookmark.deleted_at.is_not(None)
        ).update({"deleted_at": None}, synchronize_session=False)
    db.commit()

    async def _background_restore_sync(bookmark_ids: list[str]):
        # Mirror files and their index are written in a worker thread; only
        # the embedding requests (network I/O) run on the event loop.
        pending_vectors = await asyncio.to_thread(_rebuild_restored_mirrors, bookmark_ids)
        for bookmark_id, content in pending_vectors:
            # The vector was dropped when the bookmark was trashed — rebuild it
            # so the restored bookmark is findable by semantic search again.
            await index_bookmark_embedding(bookmark_id, content)

    from services import background
    background.schedule(_background_restore_sync([bm.id for bm in bms]))

    return len(bms)


def _rebuild_restored_mirrors(bookmark_ids: list[str]) -> list[tuple[str, str]]:
    """Recreate the Brain files of restored bookmarks with a fresh session.
    Returns (id, Reader text) for the ones whose vector must be rebuilt."""
    from database import SessionLocal
    with SessionLocal() as bg_db:
        bg_bms = []
        for chunk in _chunks(bookmark_ids):
            bg_bms.extend(bg_db.query(Bookmark).filter(Bookmark.id.in_(chunk)).all())
        pending_vectors = []
        for bm in bg_bms:
            _safe_brain_sync(lambda: brain_sync_service.sync_bookmark(bg_db, bm))
            if bm.scraped_content:
                pending_vectors.append((bm.id, bm.scraped_content))
        _safe_brain_sync(lambda: brain_sync_service.rebuild_index(bg_db))
    return pending_vectors


def purge_bookmarks(db: Session, ids: list[str] | None = None) -> int:
    """Permanently delete trashed bookmarks. ids=None empties the whole Trash.
    Only ever touches rows that are already in the Trash."""
    q = db.query(Bookmark).filter(Bookmark.deleted_at.is_not(None))
    if ids is None:
        purged_ids = [row.id for row in q.with_entities(Bookmark.id).all()]
    else:
        purged_ids = []
        for chunk in _chunks(list(dict.fromkeys(ids))):
            purged_ids.extend(
                row.id for row in q.filter(Bookmark.id.in_(chunk)).with_entities(Bookmark.id).all()
            )
    # Vectors are normally dropped on trashing, but clean up stragglers so a
    # hard delete never leaves orphan rows in bookmarks_vec.
    _drop_vectors(purged_ids)
    n = len(purged_ids)
    if ids is None:
        q.delete(synchronize_session=False)
    else:
        for chunk in _chunks(purged_ids):
            db.query(Bookmark).filter(
                Bookmark.deleted_at.is_not(None), Bookmark.id.in_(chunk)
            ).delete(synchronize_session=False)
    db.commit()
    delete_generated_artifacts(purged_ids)
    return n


def purge_expired(db: Session, days: int = TRASH_RETENTION_DAYS) -> int:
    """Hard-delete bookmarks that have sat in the Trash longer than `days`."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    q = db.query(Bookmark).filter(
        Bookmark.deleted_at.is_not(None), Bookmark.deleted_at < cutoff
    )
    n = q.count()
    if n:
        purged_ids = [row.id for row in q.with_entities(Bookmark.id).all()]
        _drop_vectors(purged_ids)
        q.delete(synchronize_session=False)
        db.commit()
        delete_generated_artifacts(purged_ids)
    return n


def store_scraped_content(db: Session, bookmark_id: str, content: str) -> bool:
    """Cache extracted page text on the bookmark so full-text search can match
    the article body. Best-effort — never let an indexing write break the
    caller's main flow (reader, chat, auto-tag). Returns whether the content is
    durably available after the call."""
    if not content:
        return False
    try:
        bm = db.query(Bookmark).filter(Bookmark.id == bookmark_id).first()
        if bm is None:
            return False
        if bm.scraped_content != content:
            bm.scraped_content = content
            db.commit()
        return True
    except Exception as e:
        logger.warning("storing scraped content failed: %s", e)
        db.rollback()
        return False


def _set_tags(db: Session, bm: Bookmark, tag_ids: list[str]) -> None:
    db.query(BookmarkTag).filter(BookmarkTag.bookmark_id == bm.id).delete()
    # A repeated id would violate the (bookmark_id, tag_id) primary key.
    for tag_id in dict.fromkeys(tag_ids):
        db.add(BookmarkTag(bookmark_id=bm.id, tag_id=tag_id, source="manual"))


def update_bookmark_metadata(db: Session, bm: Bookmark, meta: dict) -> Bookmark:
    """Apply metadata fetched from metadata_service to the bookmark."""
    if meta.get("description") and not bm.description:
        bm.description = meta["description"]
    if meta.get("og_image_url"):
        bm.og_image_url = meta["og_image_url"]
    if meta.get("og_image_path"):
        bm.og_image_path = meta["og_image_path"]
    if meta.get("favicon_path"):
        bm.favicon_path = meta["favicon_path"]
    db.commit()
    db.refresh(bm)
    
    # Sync with AI Brain
    _safe_brain_sync(lambda: brain_sync_service.sync_bookmark(db, bm))
    return bm


def add_note(db: Session, bookmark_id: str, content: str, source: str = "manual"):
    from models.bookmark import BookmarkNote
    note = BookmarkNote(
        bookmark_id=bookmark_id,
        content=content,
        source=source
    )
    db.add(note)
    db.commit()
    db.refresh(note)
    bm = get_bookmark(db, bookmark_id)
    if bm:
        db.expire(bm, ["bookmark_notes"])
        _safe_brain_sync(lambda: brain_sync_service.sync_bookmark(db, bm))
    return note


def delete_note(db: Session, bookmark_id: str, note_id: str):
    from models.bookmark import BookmarkNote
    note = db.query(BookmarkNote).filter(
        BookmarkNote.id == note_id, 
        BookmarkNote.bookmark_id == bookmark_id
    ).first()
    if note:
        db.delete(note)
        db.commit()
        bm = get_bookmark(db, bookmark_id)
        if bm:
            db.expire(bm, ["bookmark_notes"])
            _safe_brain_sync(lambda: brain_sync_service.sync_bookmark(db, bm))
        return True
    return False
