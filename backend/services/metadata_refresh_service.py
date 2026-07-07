"""
Bulk metadata refresh.

Re-fetches the favicon, Open Graph image and description for every bookmark and
overwrites the cached values — so broken or stale metadata (e.g. favicons saved
by an older scraper) get healed in one pass. One run at a time, progress polled
via BackgroundJob, cancellable.
"""
import asyncio

from database import SessionLocal
from models.bookmark import Bookmark
from services import metadata_service
from services.background_job import BackgroundJob


CONCURRENCY = 8

job = BackgroundJob(processed=0, total=0, updated=0)

get_status = job.get_status
is_running = job.is_running
cancel = job.cancel


async def _run_refresh(job: BackgroundJob) -> None:
    db = SessionLocal()
    try:
        rows = [(b.id, b.url) for b in db.query(Bookmark).all()]
    finally:
        db.close()

    async with job.lock:
        job.state["total"] = len(rows)

    results: list[tuple[str, dict]] = []
    sem = asyncio.Semaphore(CONCURRENCY)

    async def refresh_one(bm_id: str, url: str) -> None:
        if job.cancelled:
            return
        async with sem:
            if job.cancelled:
                return
            try:
                meta = await metadata_service.fetch_metadata(url)
            except Exception:
                meta = {}
        results.append((bm_id, meta))
        async with job.lock:
            job.state["processed"] += 1

    tasks = [asyncio.create_task(refresh_one(i, u)) for i, u in rows]
    try:
        await asyncio.gather(*tasks, return_exceptions=True)
    except asyncio.CancelledError:
        pass  # cancelled mid-run: still commit what finished ("work done is kept")

    # Batch-commit at the end (single short transaction; synchronous, so it
    # completes even after a swallowed cancellation). Overwrite cached
    # values so a forced refresh actually replaces broken favicons / stale data.
    db = SessionLocal()
    updated = 0
    try:
        for bm_id, meta in results:
            bm = db.query(Bookmark).filter(Bookmark.id == bm_id).first()
            if bm is None:
                continue
            changed = False
            if meta.get("favicon_path"):
                bm.favicon_path = meta["favicon_path"]
                changed = True
            if meta.get("og_image_url"):
                bm.og_image_url = meta["og_image_url"]
                changed = True
            if meta.get("og_image_path"):
                bm.og_image_path = meta["og_image_path"]
                changed = True
            if meta.get("description"):
                bm.description = meta["description"]
                changed = True
            if changed:
                updated += 1
        db.commit()
    finally:
        db.close()

    if not job.cancelled:
        job.state["updated"] = updated


async def start() -> dict:
    db = SessionLocal()
    try:
        total = db.query(Bookmark).count()
    finally:
        db.close()
    # Pre-load total so the UI shows a real number immediately.
    return await job.start(_run_refresh, reset={"total": total})
