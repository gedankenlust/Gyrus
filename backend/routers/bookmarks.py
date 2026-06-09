from fastapi import APIRouter, Depends, HTTPException, BackgroundTasks
from pydantic import BaseModel
from sqlalchemy.orm import Session
from sqlalchemy.exc import IntegrityError
from database import get_db, SessionLocal
from schemas.bookmark import BookmarkCreate, BookmarkUpdate, BookmarkOut, BookmarkNoteCreate, BookmarkNoteOut
from models.bookmark import Bookmark
from services import bookmark_service
from services import metadata_service
from services import link_check_service
from services import metadata_refresh_service
from services.scraper_service import scraper_service

router = APIRouter(prefix="/api/bookmarks", tags=["bookmarks"])


class AutoTagRequest(BaseModel):
    provider_config: dict | None = {"provider": "ollama", "model": "llama3"}


def _enrich(bm) -> BookmarkOut:
    out = BookmarkOut.model_validate(bm)
    # Sort tags alphabetically by name for deterministic responses
    tags = [bt.tag for bt in bm.bookmark_tags]
    out.tags = sorted(tags, key=lambda t: t.name)
    return out


async def _fetch_meta(bookmark_id: str, url: str) -> None:
    meta = await metadata_service.fetch_metadata(url)
    db = SessionLocal()
    try:
        bm = db.query(Bookmark).filter(Bookmark.id == bookmark_id).first()
        if bm:
            bookmark_service.update_bookmark_metadata(db, bm, meta)
    finally:
        db.close()


@router.get("/count", response_model=int)
def bookmark_count(db: Session = Depends(get_db)):
    return db.query(Bookmark).filter(Bookmark.deleted_at.is_(None)).count()


@router.get("/count-dead", response_model=int)
def dead_count(db: Session = Depends(get_db)):
    return db.query(Bookmark).filter(
        Bookmark.deleted_at.is_(None), Bookmark.is_dead == True
    ).count()


@router.get("/count-unread", response_model=int)
def unread_count(db: Session = Depends(get_db)):
    return db.query(Bookmark).filter(
        Bookmark.deleted_at.is_(None), Bookmark.is_read == False
    ).count()


# NOTE: these literal /trash routes MUST be declared before GET /{bookmark_id},
# otherwise "trash" would be captured as a bookmark id.
@router.get("/trash", response_model=list[BookmarkOut])
def list_trash(limit: int = 200, offset: int = 0, db: Session = Depends(get_db)):
    return [_enrich(bm) for bm in bookmark_service.get_trashed(db, limit=limit, offset=offset)]


@router.get("/trash/count", response_model=int)
def trash_count(db: Session = Depends(get_db)):
    return bookmark_service.count_trashed(db)


@router.post("/check-links")
async def start_link_check():
    return await link_check_service.start()


@router.get("/check-links/status")
async def link_check_status():
    return link_check_service.get_status()


@router.post("/refresh-metadata")
async def start_metadata_refresh():
    return await metadata_refresh_service.start()


@router.get("/refresh-metadata/status")
async def metadata_refresh_status():
    return metadata_refresh_service.get_status()


@router.post("/refresh-metadata/cancel")
async def cancel_metadata_refresh():
    return metadata_refresh_service.cancel()


@router.get("/ids", response_model=list[str])
def list_bookmark_ids(
    collection_id: str | None = None,
    tag: str | None = None,
    dead_only: bool = False,
    unread_only: bool = False,
    q: str | None = None,
    db: Session = Depends(get_db),
):
    from models.tag import Tag as TagModel, BookmarkTag
    query = db.query(Bookmark.id).filter(Bookmark.deleted_at.is_(None))
    if collection_id:
        query = query.filter(Bookmark.collection_id == collection_id)
    if dead_only:
        query = query.filter(Bookmark.is_dead == True)
    if unread_only:
        query = query.filter(Bookmark.is_read == False)
    if tag:
        query = (query
                 .join(BookmarkTag, BookmarkTag.bookmark_id == Bookmark.id)
                 .join(TagModel, TagModel.id == BookmarkTag.tag_id)
                 .filter(TagModel.name == tag))
    if q:
        like = f"%{q}%"
        query = query.filter(
            (Bookmark.title.ilike(like)) | (Bookmark.url.ilike(like))
        )
    return [row.id for row in query.all()]


@router.get("", response_model=list[BookmarkOut])
def list_bookmarks(
    collection_id: str | None = None,
    tag: str | None = None,
    dead_only: bool = False,
    unread_only: bool = False,
    limit: int = 100,
    offset: int = 0,
    sort_by: str = "created_at",
    order: str = "desc",
    db: Session = Depends(get_db),
):
    bms = bookmark_service.get_bookmarks(
        db,
        collection_id=collection_id,
        tag=tag,
        dead_only=dead_only,
        unread_only=unread_only,
        limit=limit,
        offset=offset,
        sort_by=sort_by,
        order=order,
    )
    return [_enrich(bm) for bm in bms]


@router.post("", response_model=BookmarkOut, status_code=201)
async def create_bookmark(
    data: BookmarkCreate,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
):
    try:
        bm = bookmark_service.create_bookmark(db, data)
    except IntegrityError:
        db.rollback()
        raise HTTPException(409, "Bookmark with this URL already exists")
    background_tasks.add_task(_fetch_meta, bm.id, bm.url)
    return _enrich(bm)


@router.get("/{bookmark_id}", response_model=BookmarkOut)
def get_bookmark(bookmark_id: str, db: Session = Depends(get_db)):
    bm = bookmark_service.get_bookmark(db, bookmark_id)
    if not bm:
        raise HTTPException(404, "Bookmark not found")
    return _enrich(bm)


@router.put("/{bookmark_id}", response_model=BookmarkOut)
def update_bookmark(bookmark_id: str, data: BookmarkUpdate, db: Session = Depends(get_db)):
    bm = bookmark_service.get_bookmark(db, bookmark_id)
    if not bm:
        raise HTTPException(404, "Bookmark not found")
    bm = bookmark_service.update_bookmark(db, bm, data)
    return _enrich(bm)


@router.delete("/{bookmark_id}", status_code=204)
def delete_bookmark(bookmark_id: str, db: Session = Depends(get_db)):
    bm = bookmark_service.get_bookmark(db, bookmark_id)
    if not bm:
        raise HTTPException(404, "Bookmark not found")
    bookmark_service.delete_bookmark(db, bm)


class BulkDeleteRequest(BaseModel):
    ids: list[str]


@router.post("/delete-batch", status_code=204)
def delete_bookmarks_batch(data: BulkDeleteRequest, db: Session = Depends(get_db)):
    bookmark_service.delete_bookmarks(db, data.ids)


class TrashIdsRequest(BaseModel):
    # None / omitted = act on the whole Trash (used by "Empty Trash").
    ids: list[str] | None = None


@router.post("/trash/restore")
def restore_from_trash(data: TrashIdsRequest, db: Session = Depends(get_db)):
    restored = bookmark_service.restore_bookmarks(db, data.ids or [])
    return {"restored": restored}


@router.post("/trash/purge")
def purge_trash(data: TrashIdsRequest, db: Session = Depends(get_db)):
    purged = bookmark_service.purge_bookmarks(db, data.ids)
    return {"purged": purged}


@router.post("/{bookmark_id}/fetch-meta", response_model=BookmarkOut)
async def fetch_meta(bookmark_id: str, db: Session = Depends(get_db)):
    bm = bookmark_service.get_bookmark(db, bookmark_id)
    if not bm:
        raise HTTPException(404, "Bookmark not found")
    meta = await metadata_service.fetch_metadata(bm.url)
    bm = bookmark_service.update_bookmark_metadata(db, bm, meta)
    return _enrich(bm)


@router.post("/{bookmark_id}/notes", response_model=BookmarkNoteOut, status_code=201)
def add_bookmark_note(bookmark_id: str, data: BookmarkNoteCreate, db: Session = Depends(get_db)):
    bm = bookmark_service.get_bookmark(db, bookmark_id)
    if not bm:
        raise HTTPException(404, "Bookmark not found")
    
    note = bookmark_service.add_note(db, bookmark_id, data.content, data.source)
    return note


@router.delete("/{bookmark_id}/notes/{note_id}", status_code=204)
def delete_bookmark_note(bookmark_id: str, note_id: str, db: Session = Depends(get_db)):
    success = bookmark_service.delete_note(db, bookmark_id, note_id)
    if not success:
        raise HTTPException(404, "Note not found")


class ReaderResponse(BaseModel):
    content: str


@router.get("/{bookmark_id}/reader", response_model=ReaderResponse)
async def get_reader_content(bookmark_id: str, db: Session = Depends(get_db)):
    bm = bookmark_service.get_bookmark(db, bookmark_id)
    if not bm:
        raise HTTPException(404, "Bookmark not found")

    scrape_result = await scraper_service.extract_content(bm.url)
    content = scrape_result.get("content", "")

    if content:
        # Cache the extracted text so full-text search can match the article body.
        bookmark_service.store_scraped_content(db, bookmark_id, content)
    else:
        content = "Could not extract readable content from this page."

    return ReaderResponse(content=content)


@router.post("/{bookmark_id}/auto-tag", response_model=BookmarkOut)
async def auto_tag_bookmark(bookmark_id: str, request: AutoTagRequest, db: Session = Depends(get_db)):
    bm = await bookmark_service.auto_tag_bookmark(db, bookmark_id, request.provider_config)
    if not bm:
        raise HTTPException(404, "Bookmark not found")
    return _enrich(bm)
