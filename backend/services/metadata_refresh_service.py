"""Bounded metadata refresh with incremental, durable progress."""
import asyncio
from collections import deque

from database import SessionLocal
from models.bookmark import Bookmark
from services import metadata_service
from services.background_job import BackgroundJob

CONCURRENCY = 8
ITEM_TIMEOUT = 30.0
job = BackgroundJob(processed=0, total=0, updated=0, failed=0)
get_status = job.get_status
is_running = job.is_running
cancel = job.cancel


def _rows():
    with SessionLocal() as db:
        return db.query(Bookmark.id, Bookmark.url).filter(Bookmark.deleted_at.is_(None)).all()


def _save_result(bookmark_id: str, meta: dict) -> int:
    values = {key: meta[key] for key in (
        "favicon_path", "og_image_url", "og_image_path", "description"
    ) if meta.get(key)}
    if not values:
        return 0
    with SessionLocal() as db:
        updated = db.query(Bookmark).filter(
            Bookmark.id == bookmark_id, Bookmark.deleted_at.is_(None)
        ).update(values, synchronize_session=False)
        db.commit()
        return updated


async def _run_refresh(job: BackgroundJob) -> None:
    pending = deque(await asyncio.to_thread(_rows))
    job.state["total"] = len(pending)
    # Only eight workers exist, regardless of library size. Serialize short
    # writes off the event loop so status polling stays responsive.
    write_lock = asyncio.Lock()

    async def worker():
        while pending and not job.cancelled:
            bookmark_id, url = pending.popleft()
            try:
                async with asyncio.timeout(ITEM_TIMEOUT):
                    meta = await metadata_service.fetch_metadata(url)
            except Exception:
                meta = {}
            async with write_lock:
                saving = asyncio.create_task(asyncio.to_thread(_save_result, bookmark_id, meta))
                cancelled = False
                try:
                    updated = await asyncio.shield(saving)
                except asyncio.CancelledError:
                    # A thread cannot be cancelled. Keep the job busy until its
                    # transaction ends, so a reset cannot race an old writer.
                    updated = await saving
                    cancelled = True
                job.state["updated"] += updated
                job.state["failed"] += int(not any(meta.values()))
                job.state["processed"] += 1
                if cancelled:
                    raise asyncio.CancelledError

    workers = [asyncio.create_task(worker()) for _ in range(CONCURRENCY)]
    try:
        await asyncio.gather(*workers)
    finally:
        for task in workers:
            if not task.done() and not task.cancelling():
                task.cancel()
        await asyncio.gather(*workers, return_exceptions=True)


async def start() -> dict:
    if job.is_running():
        return job.get_status()
    return await job.start(_run_refresh)
