import logging
from datetime import datetime, timezone, timedelta
from sqlalchemy.orm import Session
from sqlalchemy.exc import IntegrityError
from models.bookmark import Bookmark
from models.collection import Collection
from models.tag import Tag, BookmarkTag
from schemas.bookmark import BookmarkCreate, BookmarkUpdate
from services.brain_sync_service import brain_sync_service

logger = logging.getLogger(__name__)

# How long a bookmark stays recoverable in the Trash before it is purged.
TRASH_RETENTION_DAYS = 30


def _safe_brain_sync(action) -> None:
    """Run a brain-sync action without ever breaking the core DB operation.

    The Markdown brain is a secondary, optional feature. A filesystem hiccup
    (long filename, missing permissions, full disk) must not turn a normal
    save or delete into a 500 — the database is the source of truth.
    """
    try:
        action()
    except Exception as e:
        logger.warning("Brain sync skipped (non-fatal): %s", e)


_SORT_COLUMNS = {
    "created_at": Bookmark.created_at,
    "updated_at": Bookmark.updated_at,
    "title": Bookmark.title,
    "url": Bookmark.url,
}


def get_bookmarks(
    db: Session,
    collection_id: str | None = None,
    tag: str | None = None,
    dead_only: bool = False,
    unread_only: bool = False,
    limit: int = 100,
    offset: int = 0,
    sort_by: str = "created_at",
    order: str = "desc",
) -> list[Bookmark]:
    q = db.query(Bookmark).filter(Bookmark.deleted_at.is_(None))
    if collection_id is not None:
        q = q.filter(Bookmark.collection_id == collection_id)
    if tag:
        q = q.join(BookmarkTag).join(Tag).filter(Tag.name == tag)
    if dead_only:
        q = q.filter(Bookmark.is_dead == True)
    if unread_only:
        q = q.filter(Bookmark.is_read == False)

    if sort_by == "tag":
        # Sort by the bookmark's first tag (alphabetically); untagged go last.
        from sqlalchemy import select, func as _func
        min_tag = (
            select(_func.min(Tag.name))
            .select_from(Tag)
            .join(BookmarkTag, BookmarkTag.tag_id == Tag.id)
            .where(BookmarkTag.bookmark_id == Bookmark.id)
            .correlate(Bookmark)
            .scalar_subquery()
        )
        name_expr = _func.lower(min_tag)
        direction = name_expr.asc() if order == "asc" else name_expr.desc()
        q = q.order_by(min_tag.is_(None), direction)
    elif sort_by == "favicon":
        # Group bookmarks from the same site together. We sort by the URL's host
        # (not favicon_path) because favicons are fetched lazily — a favicon-based
        # sort would scramble as icons load in. The host is always known, so this
        # groups deterministically and immediately. www. is stripped.
        from sqlalchemy import func as _func
        after = _func.substr(Bookmark.url, _func.instr(Bookmark.url, '://') + 3)
        first_slash = _func.instr(after, '/')
        host = _func.lower(_func.substr(
            after, 1, _func.iif(first_slash > 0, first_slash - 1, _func.length(after))))
        host = _func.iif(host.like('www.%'), _func.substr(host, 5), host)
        hdir = host.asc() if order == "asc" else host.desc()
        q = q.order_by(hdir, _func.lower(Bookmark.title))
    else:
        col = _SORT_COLUMNS.get(sort_by, Bookmark.created_at)
        # Case-insensitive sort for text columns
        if sort_by in ("title", "url"):
            from sqlalchemy import func as _func
            col_expr = _func.lower(col)
        else:
            col_expr = col
        q = q.order_by(col_expr.asc() if order == "asc" else col_expr.desc())

    return q.offset(offset).limit(limit).all()


def get_bookmark(db: Session, bookmark_id: str, include_deleted: bool = False) -> Bookmark | None:
    q = db.query(Bookmark).filter(Bookmark.id == bookmark_id)
    if not include_deleted:
        q = q.filter(Bookmark.deleted_at.is_(None))
    return q.first()


def create_bookmark(db: Session, data: BookmarkCreate) -> Bookmark:
    from services.url_utils import normalize_url
    url = normalize_url(data.url)

    # Check for duplicates (against the normalized URL)
    found = db.query(Bookmark).filter(Bookmark.url == url).first()
    if found:
        from fastapi import HTTPException
        raise HTTPException(status_code=409, detail="Bookmark already exists")

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

    return bm


def update_bookmark(db: Session, bm: Bookmark, data: BookmarkUpdate) -> Bookmark:
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
    db.commit()
    db.refresh(bm)

    # Sync with AI Brain (best-effort — never block the update)
    _safe_brain_sync(lambda: brain_sync_service.sync_bookmark(db, bm, old_path=old_path))
    _safe_brain_sync(lambda: brain_sync_service.rebuild_index(db))

    # Re-embed when text the vector is built from changed, so semantic search
    # doesn't keep ranking by the old content. Same text selection as reindex:
    # scraped content if present, else title + description.
    if changed.keys() & {"title", "description", "notes", "scraped_content"}:
        text = bm.scraped_content or f"{bm.title or ''} {bm.description or ''}".strip()
        if text:
            from services import background
            background.schedule(index_bookmark_embedding(bm.id, text))

    return bm


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
    except Exception:
        pass

    bm.deleted_at = datetime.now(timezone.utc)
    db.commit()
    _safe_brain_sync(lambda: brain_sync_service.rebuild_index(db))


def delete_bookmarks(db: Session, ids: list[str]) -> None:
    """Soft-delete multiple bookmarks (move them to the Trash)."""
    # Best-effort: remove the brain markdown files (only for ones not already trashed).
    bms = db.query(Bookmark).filter(
        Bookmark.id.in_(ids), Bookmark.deleted_at.is_(None)
    ).all()
    for bm in bms:
        _safe_brain_sync(lambda: brain_sync_service.delete_bookmark_file(db, bm))
    _drop_vectors([bm.id for bm in bms])

    db.query(Bookmark).filter(
        Bookmark.id.in_(ids), Bookmark.deleted_at.is_(None)
    ).update({Bookmark.deleted_at: datetime.now(timezone.utc)}, synchronize_session=False)
    db.commit()
    _safe_brain_sync(lambda: brain_sync_service.rebuild_index(db))


def _drop_vectors(ids: list[str]) -> None:
    """Best-effort removal of semantic-search vectors for the given bookmarks.
    Trashed/purged bookmarks must not occupy KNN slots or leave orphan rows."""
    if not ids:
        return
    try:
        from services import vector_store
        for bm_id in ids:
            vector_store.delete(bm_id)
    except Exception:
        pass


def get_trashed(db: Session, limit: int = 200, offset: int = 0) -> list[Bookmark]:
    """List bookmarks currently in the Trash, most recently deleted first."""
    return (
        db.query(Bookmark)
        .filter(Bookmark.deleted_at.is_not(None))
        .order_by(Bookmark.deleted_at.desc())
        .offset(offset)
        .limit(limit)
        .all()
    )


def count_trashed(db: Session) -> int:
    return db.query(Bookmark).filter(Bookmark.deleted_at.is_not(None)).count()


def restore_bookmarks(db: Session, ids: list[str]) -> int:
    """Bring bookmarks back from the Trash and recreate their brain files."""
    bms = db.query(Bookmark).filter(
        Bookmark.id.in_(ids), Bookmark.deleted_at.is_not(None)
    ).all()
    for bm in bms:
        bm.deleted_at = None
    db.commit()
    for bm in bms:
        _safe_brain_sync(lambda: brain_sync_service.sync_bookmark(db, bm))
        # The vector was dropped when the bookmark was trashed — rebuild it
        # so the restored bookmark is findable by semantic search again.
        if bm.scraped_content:
            from services import background
            background.schedule(index_bookmark_embedding(bm.id, bm.scraped_content))
    _safe_brain_sync(lambda: brain_sync_service.rebuild_index(db))
    return len(bms)


def purge_bookmarks(db: Session, ids: list[str] | None = None) -> int:
    """Permanently delete trashed bookmarks. ids=None empties the whole Trash.
    Only ever touches rows that are already in the Trash."""
    q = db.query(Bookmark).filter(Bookmark.deleted_at.is_not(None))
    if ids is not None:
        q = q.filter(Bookmark.id.in_(ids))
    # Vectors are normally dropped on trashing, but clean up stragglers so a
    # hard delete never leaves orphan rows in bookmarks_vec.
    _drop_vectors([row.id for row in q.with_entities(Bookmark.id).all()])
    n = q.count()
    q.delete(synchronize_session=False)
    db.commit()
    return n


def purge_expired(db: Session, days: int = TRASH_RETENTION_DAYS) -> int:
    """Hard-delete bookmarks that have sat in the Trash longer than `days`."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    q = db.query(Bookmark).filter(
        Bookmark.deleted_at.is_not(None), Bookmark.deleted_at < cutoff
    )
    n = q.count()
    if n:
        _drop_vectors([row.id for row in q.with_entities(Bookmark.id).all()])
        q.delete(synchronize_session=False)
        db.commit()
    return n


def store_scraped_content(db: Session, bookmark_id: str, content: str) -> None:
    """Cache extracted page text on the bookmark so full-text search can match
    the article body. Best-effort — never let an indexing write break the
    caller's main flow (reader, chat, auto-tag)."""
    if not content:
        return
    try:
        bm = db.query(Bookmark).filter(Bookmark.id == bookmark_id).first()
        if bm is not None and bm.scraped_content != content:
            bm.scraped_content = content
            db.commit()
    except Exception as e:
        logger.warning("storing scraped content failed: %s", e)
        db.rollback()


async def index_bookmark_embedding(bookmark_id: str, text: str) -> None:
    """Compute and store an embedding for a bookmark (best-effort, never blocks
    the caller).  Called after page content is scraped so semantic search can
    find this bookmark by meaning, not just keywords."""
    if not text or not text.strip():
        return
    try:
        from services.embedding_service import get_embedding, EmbeddingUnavailableError
        from services import vector_store
        vec = await get_embedding(text)
        vector_store.upsert(bookmark_id, vec)
    except Exception as e:
        # Ollama down, model missing, DB write error — none of these should
        # affect the caller; semantic search simply won't find this bookmark.
        logger.debug("embedding indexing skipped for %s: %s", bookmark_id, e)


def _set_tags(db: Session, bm: Bookmark, tag_ids: list[str]) -> None:
    db.query(BookmarkTag).filter(BookmarkTag.bookmark_id == bm.id).delete()
    for tag_id in tag_ids:
        db.add(BookmarkTag(bookmark_id=bm.id, tag_id=tag_id))


def get_bookmark_tags(bm: Bookmark) -> list[Tag]:
    return [bt.tag for bt in bm.bookmark_tags]


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
        return True
    return False


# A small palette of distinct, dark-mode-friendly colors. Auto-tags pick from
# it deterministically by name, so the same tag is always the same color but
# different tags look visually distinct (instead of every tag being purple).
_TAG_PALETTE = [
    "#8B5CF6",  # violet
    "#3B82F6",  # blue
    "#10B981",  # emerald
    "#F59E0B",  # amber
    "#EF4444",  # red
    "#EC4899",  # pink
    "#14B8A6",  # teal
    "#F97316",  # orange
    "#6366F1",  # indigo
    "#84CC16",  # lime
]


def _color_for_tag(name: str) -> str:
    """Stable color for a tag name — same name → same color, spread across the palette."""
    import hashlib
    h = int(hashlib.sha256(name.encode("utf-8")).hexdigest(), 16)
    return _TAG_PALETTE[h % len(_TAG_PALETTE)]


async def auto_tag_bookmark(db: Session, bookmark_id: str, provider_config: dict | None = None,
                            scrape: bool = True) -> Bookmark:
    from services.scraper_service import scraper_service
    from services.llm_service import LLMService
    from fastapi import HTTPException

    bm = get_bookmark(db, bookmark_id)
    if not bm:
        raise HTTPException(status_code=404, detail="Bookmark not found")

    # 1. Get existing tags to give the LLM context
    all_tags = [t.name for t in db.query(Tag).all()]

    # 2. Build context. Scraping the full page gives the best tags but is the
    # slow part (a network fetch per bookmark) — bulk tagging skips it and tags
    # from the title/URL/description, which is plenty for broad topic tags and
    # an order of magnitude faster across a large selection.
    context = ""
    if scrape:
        scrape_result = await scraper_service.extract_content(bm.url)
        context = scrape_result.get("content", "")
        if context:
            store_scraped_content(db, bookmark_id, context)
            # Index embedding in the background so semantic search can find this
            # bookmark — fire-and-forget, uses the full text before truncation.
            from services import background
            background.schedule(index_bookmark_embedding(bookmark_id, context))
        if len(context) > 10000:
            context = context[:10000]

    if not context:
        context = f"Title: {bm.title}\nURL: {bm.url}\nDescription: {bm.description or ''}"

    # 3. Prompt the LLM. We want a FEW BROAD, reusable tags (topics that group
    # many bookmarks) — not hyper-specific ones like "list-comprehensions" or
    # "single-page-application", which clutter the sidebar and never repeat.
    prompt = (
        "You are a tagging assistant. Suggest 1-3 broad, reusable topic tags that group "
        "this content with similar bookmarks (e.g. 'python', 'ai', 'design', 'database', 'frontend'). "
        "Prefer general categories over narrow specifics: use 'python' not 'list-comprehensions', "
        "'frontend' not 'single-page-application'. Fewer, broader tags are better than many narrow ones. "
        f"Strongly prefer reusing these existing tags when any fit: {', '.join(all_tags)}. "
        "Only invent a new tag if none of the existing ones fit. "
        "Reply ONLY with lowercase tag names separated by commas. No other text."
    )
    
    try:
        response = await LLMService.ask_llm(
            prompt=prompt,
            context=context,
            provider_config=provider_config or {"provider": "ollama", "model": "llama3"},
            # Tagging is a short, mechanical task. Disable the reasoning phase
            # (qwen3/deepseek-r1 otherwise spend ~25s "thinking" per bookmark for
            # the same 3 tags) and cap output — tags are a dozen tokens at most.
            think=False,
            options={"num_predict": 64, "temperature": 0},
        )
    except Exception as e:
        raise HTTPException(500, f"LLM Error: {str(e)}")

    # 4. Parse and apply tags. (Any <think>…</think> block is already stripped by
    # LLMService, so this is plain comma-separated tag text.)
    suggested = [t.strip().lower() for t in response.split(",") if t.strip()]
    suggested = suggested[:3] # Max 3 tags
    
    current_tag_ids = [bt.tag_id for bt in bm.bookmark_tags]
    for tag_name in suggested:
        if not tag_name: continue
        tag = db.query(Tag).filter(Tag.name == tag_name).first()
        if not tag:
            tag = Tag(name=tag_name, color=_color_for_tag(tag_name))
            db.add(tag)
            db.flush()
        if tag.id not in current_tag_ids:
            current_tag_ids.append(tag.id)
        
    _set_tags(db, bm, current_tag_ids)
    db.commit()
    db.refresh(bm)
    return bm
