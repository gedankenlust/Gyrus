"""Review-first global taxonomy generation for bookmark batches."""
import asyncio

from database import SessionLocal
from models.bookmark import Bookmark
from services import bookmark_service, taxonomy_service
from services.background_job import BackgroundJob
from services.scraper_service import scraper_service


# Page extraction is I/O-bound. Keeping this modest avoids hammering sites while
# still preparing a larger collection in a reasonable amount of time.
SCRAPE_CONCURRENCY = 4

# A taxonomy only makes sense for a collection: every category must be shared
# by at least two bookmarks, and below ~10 items the clustering degenerates
# into singletons, guaranteeing a quality failure after minutes of LLM work.
# The UI disables the review button below this; the router rejects it too.
MIN_TAXONOMY_BOOKMARKS = 10

job = BackgroundJob(
    processed=0,
    total=0,
    assigned=0,
    without_tags=0,
    failed=0,
    phase="idle",
    draft=None,
    generated_tokens=0,
    model=None,
)

get_status = job.get_status
is_running = job.is_running
cancel = job.cancel


def discard_draft(draft_id: str) -> None:
    taxonomy_service.discard_draft(draft_id)
    draft = job.state.get("draft")
    if isinstance(draft, dict) and draft.get("id") == draft_id:
        job.state["draft"] = None
        job.state["assigned"] = 0
        job.state["without_tags"] = job.state.get("total", 0)
        job.state["phase"] = "idle"


async def _prepare_bookmark(bookmark_id: str, semaphore: asyncio.Semaphore,
                            job: BackgroundJob) -> bool:
    """Ensure useful Reader text exists without assigning any tags."""
    if job.cancelled:
        return False
    async with semaphore:
        db = SessionLocal()
        try:
            bookmark = db.query(Bookmark).filter(
                Bookmark.id == bookmark_id,
                Bookmark.deleted_at.is_(None),
            ).first()
            if bookmark is None:
                job.state["failed"] += 1
                return False

            if not (bookmark.scraped_content or "").strip():
                try:
                    result = await scraper_service.extract_content(bookmark.url)
                    content = (result.get("content") or "").strip()
                    if content:
                        bookmark_service.store_scraped_content(db, bookmark.id, content)
                except asyncio.CancelledError:
                    raise
                except Exception:
                    # A page can block extraction or be temporarily unavailable.
                    # Its title and description still remain valid taxonomy input.
                    pass
            return True
        finally:
            db.close()
            job.state["processed"] += 1


async def _run(ids: list[str], provider_config: dict | None, language: str | None,
               job: BackgroundJob) -> None:
    job.state["phase"] = "preparing"
    semaphore = asyncio.Semaphore(SCRAPE_CONCURRENCY)
    results = await asyncio.gather(*(
        _prepare_bookmark(bookmark_id, semaphore, job) for bookmark_id in ids
    ))
    if job.cancelled:
        job.state["phase"] = "cancelled"
        return

    valid_ids = [bookmark_id for bookmark_id, valid in zip(ids, results) if valid]
    if not valid_ids:
        job.state["phase"] = "failed"
        raise ValueError("No selected bookmarks are available for taxonomy generation.")

    job.state["phase"] = "organizing"
    job.state["generated_tokens"] = 0

    def report_progress(stage: str, generated_tokens: int) -> None:
        job.state["phase"] = stage
        job.state["generated_tokens"] = generated_tokens

    db = SessionLocal()
    try:
        bookmarks_by_id = {
            bookmark.id: bookmark
            for bookmark in db.query(Bookmark).filter(Bookmark.id.in_(valid_ids)).all()
        }
        bookmarks = [bookmarks_by_id[bookmark_id] for bookmark_id in valid_ids
                     if bookmark_id in bookmarks_by_id]
        draft = await taxonomy_service.generate_draft(
            db, bookmarks, provider_config, language, progress=report_progress
        )
    finally:
        db.close()

    job.state["draft"] = draft
    job.state["assigned"] = draft["assigned"]
    job.state["without_tags"] = draft["without_tags"]
    job.state["phase"] = "review"


async def start(ids: list[str], provider_config: dict | None = None,
                language: str | None = None) -> dict:
    # Preserve selection order while preventing duplicated work and counts.
    unique_ids = list(dict.fromkeys(ids))
    if not unique_ids:
        return await job.run_noop(reset={"total": 0, "phase": "idle"})

    async def runner(active_job: BackgroundJob) -> None:
        await _run(unique_ids, provider_config, language, active_job)

    return await job.start(
        runner,
        reset={
            "total": len(unique_ids),
            "phase": "preparing",
            "model": (provider_config or {}).get("model", "llama3"),
        },
    )
