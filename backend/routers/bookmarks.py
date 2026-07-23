from fastapi import APIRouter, Depends, HTTPException, BackgroundTasks
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session
from sqlalchemy.exc import IntegrityError
from database import get_db, SessionLocal
from schemas.bookmark import (
    BookmarkAnalysisOut,
    BookmarkCreate,
    BookmarkUpdate,
    BookmarkOut,
    BookmarkNoteCreate,
    BookmarkNoteOut,
)
from models.bookmark import Bookmark
from services import bookmark_service
from services import metadata_service
from services import link_check_service
from services import metadata_refresh_service
from services import visual_snapshot_service
from services import bookmark_enrichment_service
from services.scraper_service import scraper_service

router = APIRouter(prefix="/api/bookmarks", tags=["bookmarks"])


class AutoTagRequest(BaseModel):
    provider_config: dict | None = {"provider": "ollama", "model": "llama3"}
    # "en" / "de" — the app's UI language, so generated tags match it instead
    # of always defaulting to English regardless of what the user has set.
    language: str | None = None


def _enrich(bm) -> BookmarkOut:
    out = BookmarkOut.model_validate(bm)
    # Sort tags alphabetically by name for deterministic responses
    tags = [bt.tag for bt in bm.bookmark_tags]
    out.tags = sorted(tags, key=lambda t: t.name)
    captured_at, complete = visual_snapshot_service.snapshot_summary(bm.id)
    out.design_snapshot_captured_at = captured_at
    out.design_snapshot_complete = complete
    out.analysis = BookmarkAnalysisOut(
        **bookmark_enrichment_service.analysis_summary(
            bm,
            design_captured=captured_at is not None,
            design_complete=complete,
        )
    )
    return out



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


class AutoTagBatchRequest(BaseModel):
    bookmark_ids: list[str]
    provider_config: dict | None = {"provider": "ollama", "model": "llama3"}
    language: str | None = None


class TaxonomyTagEdit(BaseModel):
    id: str
    name: str
    enabled: bool = True


class ApplyTaxonomyRequest(BaseModel):
    draft_id: str
    tags: list[TaxonomyTagEdit]


@router.post("/auto-tag-batch")
async def start_auto_tag_batch(request: AutoTagBatchRequest):
    """Auto-tag a list of bookmarks in the background (one run at a time).
    Returns immediately with the initial status; poll /auto-tag-batch/status."""
    from services import auto_tag_batch_service
    unique_count = len(set(request.bookmark_ids))
    if unique_count < auto_tag_batch_service.MIN_TAXONOMY_BOOKMARKS:
        # A taxonomy needs shared categories (each backed by >= 2 bookmarks);
        # below this the clustering degenerates into singletons and the run is
        # guaranteed to fail after minutes of LLM work. Reject up front.
        minimum = auto_tag_batch_service.MIN_TAXONOMY_BOOKMARKS
        detail = (
            f"Wähle mindestens {minimum} Lesezeichen, um ein Tag-System zu erstellen."
            if request.language == "de"
            else f"Select at least {minimum} bookmarks to build a tag system."
        )
        raise HTTPException(status_code=422, detail=detail)
    return await auto_tag_batch_service.start(request.bookmark_ids, request.provider_config, request.language)


@router.get("/auto-tag-batch/status")
async def auto_tag_batch_status():
    from services import auto_tag_batch_service
    return auto_tag_batch_service.get_status()


@router.post("/auto-tag-batch/cancel")
async def cancel_auto_tag_batch():
    from services import auto_tag_batch_service
    return auto_tag_batch_service.cancel()


@router.post("/auto-tag-batch/apply")
def apply_auto_tag_taxonomy(request: ApplyTaxonomyRequest, db: Session = Depends(get_db)):
    """Apply a reviewed taxonomy draft in one transaction."""
    from services import taxonomy_service
    return taxonomy_service.apply_draft(
        db,
        request.draft_id,
        [tag.model_dump() for tag in request.tags],
    )


@router.delete("/auto-tag-batch/draft/{draft_id}")
def discard_auto_tag_taxonomy(draft_id: str):
    from services import auto_tag_batch_service
    auto_tag_batch_service.discard_draft(draft_id)
    return {"status": "discarded"}


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
    bookmark_enrichment_service.record_stage(bookmark_id, "metadata", "running", db=db)
    try:
        meta = await metadata_service.fetch_metadata(bm.url)
        bm = bookmark_service.update_bookmark_metadata(db, bm, meta)
        bookmark_enrichment_service.record_stage(bookmark_id, "metadata", "ready", db=db)
        db.refresh(bm)
    except Exception as exc:
        bookmark_enrichment_service.record_stage(
            bookmark_id, "metadata", "failed", f"Metadata: {exc}", db=db
        )
        raise
    return _enrich(bm)


@router.post("/{bookmark_id}/analysis/retry", response_model=BookmarkOut)
def retry_analysis(bookmark_id: str, db: Session = Depends(get_db)):
    if not bookmark_enrichment_service.retry(bookmark_id):
        raise HTTPException(404, "Bookmark not found")
    bm = bookmark_service.get_bookmark(db, bookmark_id)
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


class ReaderResponse(BaseModel):
    content: str


@router.get("/{bookmark_id}/reader", response_model=ReaderResponse)
async def get_reader_content(bookmark_id: str, db: Session = Depends(get_db)):
    bm = bookmark_service.get_bookmark(db, bookmark_id)
    if not bm:
        raise HTTPException(404, "Bookmark not found")

    # Reader text is durable local data. Re-fetching the website on every tab
    # open made previously successful articles fail later when a site added a
    # login wall, bot protection, or was temporarily unavailable.
    cached_content = (bm.scraped_content or "").strip()
    if cached_content:
        if bm.reader_status != "ready":
            bookmark_enrichment_service.record_stage(
                bookmark_id, "reader", "ready", db=db
            )
        if bm.index_status != "ready":
            bookmark_enrichment_service.schedule_index(bookmark_id, cached_content)
        return ReaderResponse(content=cached_content)

    bookmark_enrichment_service.record_stage(bookmark_id, "reader", "running", db=db)
    try:
        scrape_result = await scraper_service.extract_content(bm.url)
        content = scrape_result.get("content", "")
    except Exception as exc:
        bookmark_enrichment_service.record_stage(
            bookmark_id, "reader", "failed", f"Reader: {exc}", db=db
        )
        raise

    # Vite/React and similar sites often ship an empty <div id="root"> in the
    # HTML and render all visible text with JavaScript. Chromium is already
    # bundled for Design; use it only for this explicit Reader request.
    if not content:
        rendered = await scraper_service.extract_rendered_content(bm.url)
        content = rendered.get("content", "")

    if content:
        stored = bookmark_service.store_scraped_content(db, bookmark_id, content)
        bookmark_enrichment_service.record_stage(
            bookmark_id,
            "reader",
            "ready" if stored else "failed",
            None if stored else "Reader: Extracted text could not be stored",
            db=db,
        )
        bookmark_enrichment_service.schedule_index(bookmark_id, content)
    else:
        bookmark_enrichment_service.record_stage(
            bookmark_id,
            "reader",
            "failed",
            "Reader: No readable page text found",
            db=db,
        )
        content = ""

    return ReaderResponse(content=content)


class ReaderCleanupRequest(BaseModel):
    provider_config: dict | None = {"provider": "ollama", "model": "llama3"}


class ReaderTranslateRequest(BaseModel):
    provider_config: dict | None = {"provider": "ollama", "model": "llama3"}
    target_language: str = "de"
    content: str | None = Field(default=None, max_length=20_000)


@router.post("/{bookmark_id}/reader/cleanup", response_model=ReaderResponse)
async def cleanup_reader_content(
    bookmark_id: str, request: ReaderCleanupRequest, db: Session = Depends(get_db)
):
    """Optional, opt-in: ask the local LLM to tidy the extracted text into clean
    prose. The original cached content is NOT modified — this only returns a
    nicer rendering for display."""
    from services.llm_service import LLMService

    bm = bookmark_service.get_bookmark(db, bookmark_id)
    if not bm:
        raise HTTPException(404, "Bookmark not found")

    content = bm.scraped_content
    if not content:
        scrape_result = await scraper_service.extract_content(bm.url)
        content = scrape_result.get("content", "")
        if not content:
            rendered = await scraper_service.extract_rendered_content(bm.url)
            content = rendered.get("content", "")
        if content:
            stored = bookmark_service.store_scraped_content(db, bookmark_id, content)
            bookmark_enrichment_service.record_stage(
                bookmark_id,
                "reader",
                "ready" if stored else "failed",
                None if stored else "Reader: Extracted text could not be stored",
                db=db,
            )
            bookmark_enrichment_service.schedule_index(bookmark_id, content)
    if not content:
        raise HTTPException(422, "No readable content to clean up")

    prompt = (
        "Turn the extracted article text below into clean, readable Markdown. "
        "Fix broken line breaks and spacing, preserve meaningful headings, "
        "paragraphs, quotations, and lists. Remove navigation breadcrumbs, "
        "duplicated metadata, schema.org field labels, and repeated summaries. "
        "Do not invent facts or summarize the article. Return only the cleaned "
        "article text in its original language."
    )
    try:
        cleaned = await LLMService.ask_llm(
            prompt=prompt, context=content[:15000],
            provider_config=request.provider_config or {"provider": "ollama", "model": "llama3"},
            title=bm.title or "", url=bm.url or "",
            think=False,
        )
    except Exception as e:
        raise HTTPException(502, f"LLM cleanup failed: {e}")

    return ReaderResponse(content=cleaned or content)


@router.post("/{bookmark_id}/reader/translate", response_model=ReaderResponse)
async def translate_reader_content(
    bookmark_id: str, request: ReaderTranslateRequest, db: Session = Depends(get_db)
):
    """Translate the current Reader text while preserving its Markdown layout."""
    from services.llm_service import LLMService

    bm = bookmark_service.get_bookmark(db, bookmark_id)
    if not bm:
        raise HTTPException(404, "Bookmark not found")

    content = (request.content or bm.scraped_content or "").strip()
    if not content:
        raise HTTPException(422, "No readable content to translate")

    language = request.target_language if request.target_language in {"de", "en"} else "de"
    language_name = "German" if language == "de" else "English"
    prompt = (
        f"Translate the Reader text below into {language_name}. Preserve its "
        "Markdown headings, paragraphs, lists, quotations, names, links, numbers, "
        "and meaning. Do not summarize or add commentary. Return only the translation."
    )
    try:
        translated = await LLMService.ask_llm(
            prompt=prompt,
            context=content[:15_000],
            provider_config=request.provider_config or {"provider": "ollama", "model": "llama3"},
            title=bm.title or "",
            url=bm.url or "",
            think=False,
            language=language,
        )
    except Exception as e:
        raise HTTPException(502, f"LLM translation failed: {e}")

    return ReaderResponse(content=translated or content)


@router.post("/{bookmark_id}/auto-tag", response_model=BookmarkOut)
async def auto_tag_bookmark(bookmark_id: str, request: AutoTagRequest, db: Session = Depends(get_db)):
    bm = await bookmark_service.auto_tag_bookmark(
        db,
        bookmark_id,
        provider_config=request.provider_config,
        language=request.language,
    )
    return _enrich(bm)
