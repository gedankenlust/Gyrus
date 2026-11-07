"""Reader endpoints under /api/bookmarks/{bookmark_id}/reader.

Every handler here has to await the network (page extraction, Chromium, the
LLM), so they stay `async def`. Their database work runs in the threadpool,
one call at a time on the request's session, so a locked SQLite file only
holds up this request instead of the whole event loop. Background indexing is
scheduled from the loop itself, as before.

This router has no prefix of its own: routers/bookmarks.py includes it.
"""
import logging

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session
from starlette.concurrency import run_in_threadpool

from database import get_db
from services import ai_policy
from services import bookmark_enrichment_service
from services import bookmark_service
from services.scraper_service import scraper_service

router = APIRouter()
logger = logging.getLogger(__name__)

class ReaderResponse(BaseModel):
    content: str


class ReaderCleanupRequest(BaseModel):
    provider_config: dict | None = {"provider": "ollama", "model": "llama3"}


class ReaderTranslateRequest(BaseModel):
    provider_config: dict | None = {"provider": "ollama", "model": "llama3"}
    target_language: str = "de"
    content: str | None = Field(default=None, max_length=20_000)


def _reader_failure(errors: list[str | None]) -> tuple[int, str, str]:
    details = [str(error).strip() for error in errors if error and str(error).strip()]
    combined = " | ".join(details)
    lowered = combined.casefold()
    diagnostic = f"Reader: {combined or 'No readable page text found'}"[:2_000]

    if "timeout" in lowered or "timed out" in lowered:
        return 504, "The page did not respond in time. Try again.", diagnostic
    if "ssl" in lowered or "certificate" in lowered:
        return 422, "The page's security certificate could not be verified.", diagnostic
    if any(code in lowered for code in ("http 401", "http 403", "status 401", "status 403")):
        return 422, "The page blocked access to its content.", diagnostic
    if "unsupported content type" in lowered:
        return 422, "This type of page cannot be opened in Reader.", diagnostic
    if "safety limit" in lowered or "too large" in lowered:
        return 413, "The page is too large to process safely.", diagnostic
    return 422, "No readable content could be extracted from this page.", diagnostic


# -- Threadpool sections ---------------------------------------------------
# Plain values cross back to the event loop, never ORM objects, so nothing
# lazy-loads an expired attribute from the database on the loop.

def _bookmark_fields(db: Session, bookmark_id: str) -> dict:
    bm = bookmark_service.get_bookmark(db, bookmark_id)
    if not bm:
        raise HTTPException(404, "Bookmark not found")
    return {
        "url": bm.url,
        "title": bm.title or "",
        "scraped_content": bm.scraped_content,
    }


def _open_reader(db: Session, bookmark_id: str) -> tuple[str, str, bool]:
    """(url, cached text, needs indexing). Marks the Reader stage either ready
    (durable text exists) or running (an extraction is about to start)."""
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
        # Read after record_stage: marking Reader ready may queue indexing.
        return bm.url, cached_content, bm.index_status != "ready"

    url = bm.url
    bookmark_enrichment_service.record_stage(bookmark_id, "reader", "running", db=db)
    return url, "", False


def _store_reader_text(db: Session, bookmark_id: str, content: str) -> None:
    stored = bookmark_service.store_scraped_content(db, bookmark_id, content)
    bookmark_enrichment_service.record_stage(
        bookmark_id,
        "reader",
        "ready" if stored else "failed",
        None if stored else "Reader: Extracted text could not be stored",
        db=db,
    )


# -- Routes ----------------------------------------------------------------

@router.get("/{bookmark_id}/reader", response_model=ReaderResponse)
async def get_reader_content(bookmark_id: str, db: Session = Depends(get_db)):
    url, cached_content, needs_index = await run_in_threadpool(_open_reader, db, bookmark_id)
    if cached_content:
        if needs_index:
            bookmark_enrichment_service.schedule_index(bookmark_id, cached_content)
        return ReaderResponse(content=cached_content)

    scrape_error = None
    rendered_error = None
    try:
        scrape_result = await scraper_service.extract_content(url)
        content = (scrape_result.get("content") or "").strip()
        scrape_error = scrape_result.get("error")
    except Exception as exc:
        content = ""
        scrape_error = str(exc)

    # Vite/React and similar sites often ship an empty <div id="root"> in the
    # HTML and render all visible text with JavaScript. Chromium is already
    # bundled for Design; use it only for this explicit Reader request.
    if not content:
        try:
            rendered = await scraper_service.extract_rendered_content(url)
            content = (rendered.get("content") or "").strip()
            rendered_error = rendered.get("error")
        except Exception as exc:
            rendered_error = str(exc)

    if content:
        await run_in_threadpool(_store_reader_text, db, bookmark_id, content)
        bookmark_enrichment_service.schedule_index(bookmark_id, content)
    else:
        status_code, message, diagnostic = _reader_failure(
            [scrape_error, rendered_error]
        )
        await run_in_threadpool(
            bookmark_enrichment_service.record_stage,
            bookmark_id,
            "reader",
            "failed",
            diagnostic,
            db=db,
        )
        raise HTTPException(status_code=status_code, detail=message)

    return ReaderResponse(content=content)


@router.post("/{bookmark_id}/reader/cleanup", dependencies=[Depends(ai_policy.require_ai)], response_model=ReaderResponse)
async def cleanup_reader_content(
    bookmark_id: str, request: ReaderCleanupRequest, db: Session = Depends(get_db)
):
    """Optional, opt-in: ask the local LLM to tidy the extracted text into clean
    prose. The original cached content is NOT modified — this only returns a
    nicer rendering for display."""
    from services.llm_service import LLMService

    bm = await run_in_threadpool(_bookmark_fields, db, bookmark_id)

    content = bm["scraped_content"]
    if not content:
        scrape_result = await scraper_service.extract_content(bm["url"])
        content = scrape_result.get("content", "")
        if not content:
            rendered = await scraper_service.extract_rendered_content(bm["url"])
            content = rendered.get("content", "")
        if content:
            await run_in_threadpool(_store_reader_text, db, bookmark_id, content)
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
            title=bm["title"], url=bm["url"] or "",
            think=False,
        )
    except Exception:
        # Provider errors may contain URLs, local paths or response bodies.
        logger.exception("Reader cleanup LLM request failed for bookmark %s", bookmark_id)
        raise HTTPException(502, "LLM cleanup failed. Check the AI settings and try again.")

    return ReaderResponse(content=cleaned or content)


@router.post("/{bookmark_id}/reader/translate", dependencies=[Depends(ai_policy.require_ai)], response_model=ReaderResponse)
async def translate_reader_content(
    bookmark_id: str, request: ReaderTranslateRequest, db: Session = Depends(get_db)
):
    """Translate the current Reader text while preserving its Markdown layout."""
    from services.llm_service import LLMService

    bm = await run_in_threadpool(_bookmark_fields, db, bookmark_id)

    content = (request.content or bm["scraped_content"] or "").strip()
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
            title=bm["title"],
            url=bm["url"] or "",
            think=False,
            language=language,
        )
    except Exception:
        logger.exception("Reader translation LLM request failed for bookmark %s", bookmark_id)
        raise HTTPException(502, "LLM translation failed. Check the AI settings and try again.")

    return ReaderResponse(content=translated or content)
