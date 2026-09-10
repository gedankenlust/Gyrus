"""Review-first global taxonomy generation for bookmark batches."""
import asyncio
from sqlalchemy import func

from database import SessionLocal
from models.bookmark import Bookmark
from services import taxonomy_service
from services.background_job import BackgroundJob


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
    embedded=0,
    classified=0,
    cooldown_remaining=0,
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


def _saved_bookmarks(ids: list[str]) -> dict[str, Bookmark]:
    with SessionLocal() as db:
        rows = db.query(
            Bookmark.id, Bookmark.title, Bookmark.url,
            func.substr(Bookmark.description, 1, 360).label("description"),
            func.substr(Bookmark.scraped_content, 1, taxonomy_service.MAX_EXCERPT_CHARS).label("scraped_content"),
        ).filter(Bookmark.id.in_(ids), Bookmark.deleted_at.is_(None)).all()
        return {row.id: Bookmark(**row._mapping) for row in rows}


async def _run(ids: list[str], provider_config: dict | None, language: str | None,
               job: BackgroundJob) -> None:
    job.state["phase"] = "preparing"

    def report_progress(stage: str, count: int) -> None:
        if stage == "embedded":
            job.state["embedded"] = count
        elif stage == "classified":
            job.state["classified"] = count
        elif stage == "cooldown":
            job.state["phase"] = stage
            job.state["cooldown_remaining"] = count
        else:
            job.state["phase"] = stage
            job.state["generated_tokens"] = count

    # Use saved titles, descriptions and Reader excerpts. Re-fetching thousands
    # of pages here made tag organization depend on every site's availability.
    # Metadata/Reader refresh remains a separate, explicit action.
    db = SessionLocal()
    try:
        bookmarks_by_id = {}
        for offset in range(0, len(ids), 500):
            bookmarks_by_id.update(await asyncio.to_thread(_saved_bookmarks, ids[offset:offset + 500]))
            job.state["processed"] = min(offset + 500, len(ids))
            await asyncio.sleep(0)
        bookmarks = [bookmarks_by_id[id_] for id_ in ids if id_ in bookmarks_by_id]
        job.state["failed"] = len(ids) - len(bookmarks)
        if not bookmarks:
            raise ValueError("No selected bookmarks are available for taxonomy generation.")
        draft = await taxonomy_service.generate_draft(
            db, bookmarks, provider_config, language, progress=report_progress
        )
    except asyncio.CancelledError:
        job.state["phase"] = "cancelled"
        raise
    finally:
        db.close()

    job.state["draft"] = draft
    job.state["assigned"] = draft["assigned"]
    job.state["without_tags"] = draft["without_tags"]
    job.state["phase"] = "review"


async def start(ids: list[str], provider_config: dict | None = None,
                language: str | None = None) -> dict:
    # Preserve selection order while preventing duplicated work and counts.
    unique_ids = sorted(set(ids))
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
