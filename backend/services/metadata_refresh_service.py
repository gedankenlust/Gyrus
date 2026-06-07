"""
Bulk metadata refresh.

Re-fetches the favicon, Open Graph image and description for every bookmark and
overwrites the cached values — so broken or stale metadata (e.g. favicons saved
by an older scraper) get healed in one pass. Runs as a background asyncio task
and stores progress in a module-level dict for polling, mirroring the
link-check service. One run at a time.
"""
import asyncio
from datetime import datetime, timezone

from database import SessionLocal
from models.bookmark import Bookmark
from services import metadata_service


_state: dict = {
    "running": False,
    "processed": 0,
    "total": 0,
    "updated": 0,
    "started_at": None,
    "finished_at": None,
}
_task: asyncio.Task | None = None
_lock = asyncio.Lock()
_cancelled = False

CONCURRENCY = 8


def get_status() -> dict:
    return dict(_state)


def is_running() -> bool:
    return _state["running"]


def cancel() -> dict:
    """Request the running refresh to stop. Work already done is kept."""
    global _cancelled
    if _state["running"]:
        _cancelled = True
    return get_status()


async def _run_refresh() -> None:
    db = SessionLocal()
    try:
        rows = [(b.id, b.url) for b in db.query(Bookmark).all()]
    finally:
        db.close()

    async with _lock:
        _state["total"] = len(rows)
        _state["processed"] = 0
        _state["updated"] = 0

    results: list[tuple[str, dict]] = []
    sem = asyncio.Semaphore(CONCURRENCY)

    async def refresh_one(bm_id: str, url: str) -> None:
        if _cancelled:
            return
        async with sem:
            if _cancelled:
                return
            try:
                meta = await metadata_service.fetch_metadata(url)
            except Exception:
                meta = {}
        results.append((bm_id, meta))
        async with _lock:
            _state["processed"] += 1

    tasks = [asyncio.create_task(refresh_one(i, u)) for i, u in rows]
    await asyncio.gather(*tasks, return_exceptions=True)

    # Batch-commit at the end (single short transaction). Overwrite cached
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

    async with _lock:
        _state["updated"] = updated
        _state["running"] = False
        _state["finished_at"] = datetime.now(timezone.utc).isoformat()


async def start() -> dict:
    global _task, _cancelled
    if _state["running"]:
        return get_status()
    _cancelled = False

    async with _lock:
        _state["running"] = True
        _state["started_at"] = datetime.now(timezone.utc).isoformat()
        _state["finished_at"] = None
        db = SessionLocal()
        try:
            _state["total"] = db.query(Bookmark).count()
            _state["processed"] = 0
            _state["updated"] = 0
        finally:
            db.close()

    _task = asyncio.create_task(_run_refresh())
    return get_status()
