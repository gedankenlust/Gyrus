import logging
from sqlalchemy.orm import Session
from sqlalchemy.exc import IntegrityError
from models.bookmark import Bookmark
from models.collection import Collection
from models.tag import Tag, BookmarkTag
from schemas.bookmark import BookmarkCreate, BookmarkUpdate
from services.brain_sync_service import brain_sync_service

logger = logging.getLogger(__name__)


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
    limit: int = 100,
    offset: int = 0,
    sort_by: str = "created_at",
    order: str = "desc",
) -> list[Bookmark]:
    q = db.query(Bookmark)
    if collection_id is not None:
        q = q.filter(Bookmark.collection_id == collection_id)
    if tag:
        q = q.join(BookmarkTag).join(Tag).filter(Tag.name == tag)
    if dead_only:
        q = q.filter(Bookmark.is_dead == True)

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


def get_bookmark(db: Session, bookmark_id: str) -> Bookmark | None:
    return db.query(Bookmark).filter(Bookmark.id == bookmark_id).first()


def create_bookmark(db: Session, data: BookmarkCreate) -> Bookmark:
    from services.url_utils import normalize_url
    url = normalize_url(data.url)

    # Check for duplicates (against the normalized URL)
    found = db.query(Bookmark).filter(Bookmark.url == url).first()
    if found:
        from fastapi import HTTPException
        raise HTTPException(status_code=409, detail="Bookmark already exists")

    collection_id = data.collection_id

    # Extension logic: automatic Inbox assignment
    if data.source == "extension" and not collection_id:
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

    for field, value in data.model_dump(exclude_unset=True, exclude={"tag_ids"}).items():
        setattr(bm, field, value)
    if data.tag_ids is not None:
        _set_tags(db, bm, data.tag_ids)
    db.commit()
    db.refresh(bm)

    # Sync with AI Brain (best-effort — never block the update)
    _safe_brain_sync(lambda: brain_sync_service.sync_bookmark(db, bm, old_path=old_path))
    _safe_brain_sync(lambda: brain_sync_service.rebuild_index(db))

    return bm


def delete_bookmark(db: Session, bm: Bookmark) -> None:
    # Delete file from AI Brain first while we still have access to the DB
    # relations — best-effort, so a filesystem error never blocks the delete.
    db_session = Session.object_session(bm)
    _safe_brain_sync(lambda: brain_sync_service.delete_bookmark_file(db_session, bm))

    db.delete(bm)
    db.commit()
    _safe_brain_sync(lambda: brain_sync_service.rebuild_index(db))


def delete_bookmarks(db: Session, ids: list[str]) -> None:
    """Delete multiple bookmarks by ID efficiently."""
    # 1. Fetch bookmarks to sync with AI Brain (Markdown files)
    bms = db.query(Bookmark).filter(Bookmark.id.in_(ids)).all()
    
    # 2. Best-effort brain sync for each (deletes the .md files)
    for bm in bms:
        _safe_brain_sync(lambda: brain_sync_service.delete_bookmark_file(db, bm))
    
    # 3. Bulk delete from DB
    db.query(Bookmark).filter(Bookmark.id.in_(ids)).delete(synchronize_session=False)
    db.commit()
    
    # 4. Rebuild FTS index once
    _safe_brain_sync(lambda: brain_sync_service.rebuild_index(db))


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


async def auto_tag_bookmark(db: Session, bookmark_id: str, provider_config: dict | None = None) -> Bookmark:
    from services.scraper_service import scraper_service
    from services.llm_service import LLMService
    from fastapi import HTTPException

    bm = get_bookmark(db, bookmark_id)
    if not bm:
        raise HTTPException(status_code=404, detail="Bookmark not found")
        
    # 1. Get existing tags to give the LLM context
    all_tags = [t.name for t in db.query(Tag).all()]
    
    # 2. Extract content
    scrape_result = await scraper_service.extract_content(bm.url)
    context = scrape_result.get("content", "")
    if len(context) > 10000:
        context = context[:10000]
        
    if not context:
        context = f"Title: {bm.title}\nDescription: {bm.description}"

    # 3. Prompt the LLM
    prompt = (
        f"You are a tagging assistant. Based on the following content, suggest up to 3 concise, relevant tags. "
        f"Prefer these existing tags if they fit: {', '.join(all_tags)}. "
        f"If no existing tags fit, suggest new ones. "
        f"Reply ONLY with the tag names, separated by commas, in lowercase. No other text."
    )
    
    try:
        response = await LLMService.ask_llm(
            prompt=prompt,
            context=context,
            provider_config=provider_config or {"provider": "ollama", "model": "llama3"}
        )
    except Exception as e:
        raise HTTPException(500, f"LLM Error: {str(e)}")

    # 4. Parse and apply tags
    suggested = [t.strip().lower() for t in response.split(",") if t.strip()]
    suggested = suggested[:3] # Max 3 tags
    
    current_tag_ids = [bt.tag_id for bt in bm.bookmark_tags]
    for tag_name in suggested:
        if not tag_name: continue
        tag = db.query(Tag).filter(Tag.name == tag_name).first()
        if not tag:
            tag = Tag(name=tag_name, color="#8B5CF6") # Default purple for AI tags
            db.add(tag)
            db.flush()
        if tag.id not in current_tag_ids:
            current_tag_ids.append(tag.id)
        
    _set_tags(db, bm, current_tag_ids)
    db.commit()
    db.refresh(bm)
    return bm
