import asyncio
import logging
from typing import Literal
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query, Response
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session
from sqlalchemy.exc import IntegrityError
from starlette.concurrency import run_in_threadpool
from database import get_db
from schemas.bookmark import (
    BookmarkCreate,
    BookmarkUpdate,
    BookmarkOut,
    BookmarkSummaryOut,
    BookmarkNoteCreate,
    BookmarkNoteOut,
)
from services import ai_policy
from services import bookmark_service
from services import bookmark_query_service
from services import metadata_service
from services import bookmark_enrichment_service
from services import bookmark_response_service
from routers import bookmark_jobs, reader
# Not used here since the Reader routes moved to routers/reader.py; kept so
# `routers.bookmarks.scraper_service` still names the shared scraper object.
from services.scraper_service import scraper_service  # noqa: F401

router = APIRouter(prefix="/api/bookmarks", tags=["bookmarks"])
logger = logging.getLogger(__name__)

# The sorts bookmark_query_service.get_bookmarks implements (_SORT_COLUMNS plus
# "tag" and "favicon"). Unknown values used to fall back silently to
# created_at, hiding client bugs; now they are a 422.
SortField = Literal["created_at", "updated_at", "title", "url", "tag", "favicon"]
SortOrder = Literal["asc", "desc"]


class AutoTagRequest(BaseModel):
    provider_config: dict | None = {"provider": "ollama", "model": "llama3"}
    # "en" / "de" — the app's UI language, so generated tags match it instead
    # of always defaulting to English regardless of what the user has set.
    language: str | None = None


def _enrich(bm) -> BookmarkOut:
    return bookmark_response_service.enrich_bookmark(bm)


def _enrich_summary(bm) -> BookmarkSummaryOut:
    return bookmark_response_service.enrich_bookmark_summary(bm)


class BookmarkCountsOut(BaseModel):
    total: int
    dead: int
    unread: int
    trash: int


class BookmarkSelectionRequest(BaseModel):
    bookmark_ids: list[str] = Field(max_length=100_000)


@router.post("/tagged-ids", response_model=list[str])
def tagged_bookmark_ids(request: BookmarkSelectionRequest, db: Session = Depends(get_db)):
    """Read tag membership for a selection without loading bookmark content."""
    return bookmark_query_service.tagged_bookmark_ids(db, request.bookmark_ids)


@router.get("/count", response_model=int)
def bookmark_count(db: Session = Depends(get_db)):
    return bookmark_query_service.count_active(db)


@router.get("/count-dead", response_model=int)
def dead_count(db: Session = Depends(get_db)):
    return bookmark_query_service.count_dead(db)


@router.get("/count-unread", response_model=int)
def unread_count(db: Session = Depends(get_db)):
    return bookmark_query_service.count_unread(db)


@router.get("/counts", response_model=BookmarkCountsOut)
def bookmark_counts(db: Session = Depends(get_db)):
    return BookmarkCountsOut(**bookmark_query_service.library_counts(db))


# NOTE: these literal /trash routes MUST be declared before GET /{bookmark_id},
# otherwise "trash" would be captured as a bookmark id.
@router.get("/trash", response_model=list[BookmarkSummaryOut])
def list_trash(
    limit: int = Query(default=200, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    db: Session = Depends(get_db),
):
    return [
        _enrich_summary(bm)
        for bm in bookmark_service.get_trashed(db, limit=limit, offset=offset)
    ]


@router.get("/trash/count", response_model=int)
def trash_count(db: Session = Depends(get_db)):
    return bookmark_service.count_trashed(db)


@router.get("/trash/{bookmark_id}", response_model=BookmarkOut)
def get_trashed_bookmark(bookmark_id: str, db: Session = Depends(get_db)):
    bm = bookmark_service.get_bookmark(db, bookmark_id, include_deleted=True)
    if not bm or bm.deleted_at is None:
        raise HTTPException(404, "Trashed bookmark not found")
    return _enrich(bm)


# Background jobs (/check-links, /refresh-metadata, /auto-tag-batch,
# /organize-folders). Their static paths must be registered before the
# /{bookmark_id} routes below; include_router copies routes in call order.
router.include_router(bookmark_jobs.router)


@router.get("/ids", response_model=list[str])
def list_bookmark_ids(
    collection_id: str | None = None,
    tag: str | None = None,
    dead_only: bool = False,
    unread_only: bool = False,
    q: str | None = None,
    db: Session = Depends(get_db),
):
    return bookmark_query_service.list_bookmark_ids(
        db,
        collection_id=collection_id,
        tag=tag,
        dead_only=dead_only,
        unread_only=unread_only,
        q=q,
    )


@router.get("", response_model=list[BookmarkSummaryOut])
def list_bookmarks(
    collection_id: str | None = None,
    tag: str | None = None,
    dead_only: bool = False,
    unread_only: bool = False,
    limit: int = Query(default=100, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    sort_by: SortField = "created_at",
    order: SortOrder = "desc",
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
    return [_enrich_summary(bm) for bm in bms]


@router.post("", response_model=BookmarkOut, status_code=201)
def create_bookmark(
    data: BookmarkCreate,
    background_tasks: BackgroundTasks,
    response: Response,
    db: Session = Depends(get_db),
):
    try:
        bm, restored = bookmark_service.create_or_restore_bookmark(db, data)
    except IntegrityError:
        db.rollback()
        raise HTTPException(409, "Bookmark with this URL already exists")
    if restored:
        # Still a successful create for clients; this lets the app say
        # "restored from Trash" instead of "saved".
        response.headers["X-Gyrus-Restored-From-Trash"] = "true"
    # Every entry path gets the same lightweight enrichment contract. The
    # background task only queues durable work and returns immediately.
    background_tasks.add_task(bookmark_enrichment_service.schedule_enrichment, bm.id)
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
    # The service chunks the id list below SQLite's parameter limit; this cap
    # only bounds the request (matches the largest restorable library).
    ids: list[str] = Field(max_length=250_000)


@router.post("/delete-batch", status_code=204)
def delete_bookmarks_batch(data: BulkDeleteRequest, db: Session = Depends(get_db)):
    bookmark_service.delete_bookmarks(db, data.ids)


class BulkMoveRequest(BaseModel):
    ids: list[str] = Field(min_length=1, max_length=5_000)
    collection_id: str | None = None


class BulkReadRequest(BaseModel):
    ids: list[str] = Field(min_length=1, max_length=5_000)
    is_read: bool


@router.post("/move-batch")
def move_bookmarks_batch(data: BulkMoveRequest, db: Session = Depends(get_db)):
    try:
        moved = bookmark_service.move_bookmarks(db, data.ids, data.collection_id)
    except LookupError as exc:
        db.rollback()
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    return {"updated": moved}


@router.post("/read-batch")
def read_bookmarks_batch(data: BulkReadRequest, db: Session = Depends(get_db)):
    try:
        updated = bookmark_service.set_bookmarks_read(db, data.ids, data.is_read)
    except LookupError as exc:
        db.rollback()
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    return {"updated": updated}


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


# Scrolling may request many missing favicons. Wait before checking out a DB
# connection, and never hold a transaction while a remote website responds.
_metadata_fetch_slots = asyncio.Semaphore(3)


def _begin_metadata_fetch(db: Session, bookmark_id: str) -> str:
    bm = bookmark_service.get_bookmark(db, bookmark_id)
    if not bm:
        raise HTTPException(404, "Bookmark not found")
    url = bm.url
    bookmark_enrichment_service.record_stage(bookmark_id, "metadata", "running", db=db)
    db.close()
    return url


def _finish_metadata_fetch(db: Session, bookmark_id: str, url: str, meta: dict) -> BookmarkOut:
    # Reload after network I/O: a bookmark may have been edited/deleted.
    bm = bookmark_service.get_bookmark(db, bookmark_id)
    if not bm:
        raise HTTPException(404, "Bookmark not found")
    if bm.url != url:
        raise HTTPException(409, "Bookmark URL changed during metadata fetch")
    bm = bookmark_service.update_bookmark_metadata(db, bm, meta)
    bookmark_enrichment_service.record_stage(bookmark_id, "metadata", "ready", db=db)
    db.refresh(bm)
    return _enrich(bm)


def _fail_metadata_fetch(db: Session, bookmark_id: str, error: str, rollback: bool) -> None:
    if rollback:
        db.rollback()
    bookmark_enrichment_service.record_stage(bookmark_id, "metadata", "failed", error, db=db)


@router.post("/{bookmark_id}/fetch-meta", response_model=BookmarkOut)
async def fetch_meta(bookmark_id: str, db: Session = Depends(get_db)):
    # Database sections run in the threadpool (anyio lets them finish even
    # when the request is cancelled); only the website fetch runs on the loop.
    async with _metadata_fetch_slots:
        url = await run_in_threadpool(_begin_metadata_fetch, db, bookmark_id)
        try:
            meta = await metadata_service.fetch_metadata(url)
            return await run_in_threadpool(_finish_metadata_fetch, db, bookmark_id, url, meta)
        except HTTPException:
            raise
        except asyncio.CancelledError:
            await run_in_threadpool(
                _fail_metadata_fetch, db, bookmark_id, "Metadata request cancelled", False
            )
            raise
        except Exception:
            await run_in_threadpool(
                _fail_metadata_fetch, db, bookmark_id, "Metadata fetch failed", True
            )
            raise
        finally:
            await run_in_threadpool(db.close)


@router.post("/{bookmark_id}/analysis/retry", response_model=BookmarkOut)
def retry_analysis(bookmark_id: str, db: Session = Depends(get_db)):
    if not bookmark_enrichment_service.retry(bookmark_id):
        raise HTTPException(404, "Bookmark not found")
    bm = bookmark_service.get_bookmark(db, bookmark_id)
    # It may have been trashed or purged between the retry and this read.
    if bm is None:
        raise HTTPException(404, "Bookmark not found")
    db.refresh(bm)
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


# /{bookmark_id}/reader, /reader/cleanup and /reader/translate.
router.include_router(reader.router)


@router.post("/{bookmark_id}/auto-tag", dependencies=[Depends(ai_policy.require_ai)], response_model=BookmarkOut)
async def auto_tag_bookmark(bookmark_id: str, request: AutoTagRequest, db: Session = Depends(get_db)):
    bm = await bookmark_service.auto_tag_bookmark(
        db,
        bookmark_id,
        provider_config=request.provider_config,
        language=request.language,
    )
    # Serializing loads tags and reads the design snapshot summary from disk.
    return await run_in_threadpool(_enrich, bm)
