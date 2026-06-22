"""
Bulk AI auto-tagging.

Runs the per-bookmark auto-tagger over a selected list of bookmark IDs in the
background, so the user can tag many (or all) bookmarks at once without freezing
the app. Mirrors metadata_refresh_service: one run at a time, progress polled
via a module-level dict, cancellable. Concurrency is deliberately low — each tag
means a page scrape plus a local LLM call, and too many in parallel would just
thrash Ollama.
"""
import asyncio
from datetime import datetime, timezone

from database import SessionLocal
from services import bookmark_service


_state: dict = {
    "running": False,
    "processed": 0,
    "total": 0,
    "tagged": 0,
    "started_at": None,
    "finished_at": None,
}
_task: asyncio.Task | None = None
_lock = asyncio.Lock()
_cancelled = False

CONCURRENCY = 2  # scrape + local LLM per item — keep Ollama from thrashing


def get_status() -> dict:
    return dict(_state)


def is_running() -> bool:
    return _state["running"]


def cancel() -> dict:
    """Request the running batch to stop. Tags already written are kept."""
    global _cancelled
    if _state["running"]:
        _cancelled = True
    return get_status()


async def _run(ids: list[str], provider_config: dict | None) -> None:
    sem = asyncio.Semaphore(CONCURRENCY)
    tagged = 0

    async def tag_one(bm_id: str) -> None:
        nonlocal tagged
        if _cancelled:
            return
        async with sem:
            if _cancelled:
                return
            # Each concurrent task gets its own session — a Session is not safe
            # to share across concurrent coroutines.
            db = SessionLocal()
            try:
                # scrape=False: tag from title/URL/description, skipping the
                # per-page network fetch — far faster across a big selection.
                await bookmark_service.auto_tag_bookmark(db, bm_id, provider_config, scrape=False)
                tagged += 1
            except Exception:
                pass  # one failure (missing bookmark, LLM hiccup) must not abort the batch
            finally:
                db.close()
        async with _lock:
            _state["processed"] += 1

    tasks = [asyncio.create_task(tag_one(i)) for i in ids]
    try:
        await asyncio.gather(*tasks, return_exceptions=True)
    finally:
        async with _lock:
            _state["tagged"] = tagged
            _state["running"] = False
            _state["finished_at"] = datetime.now(timezone.utc).isoformat()


async def start(ids: list[str], provider_config: dict | None = None) -> dict:
    global _task, _cancelled
    if _state["running"]:
        return get_status()
    _cancelled = False

    async with _lock:
        _state["running"] = True
        _state["processed"] = 0
        _state["total"] = len(ids)
        _state["tagged"] = 0
        _state["started_at"] = datetime.now(timezone.utc).isoformat()
        _state["finished_at"] = None

    if not ids:
        # Nothing to do — mark finished immediately so the poller stops.
        async with _lock:
            _state["running"] = False
            _state["finished_at"] = datetime.now(timezone.utc).isoformat()
        return get_status()

    _task = asyncio.create_task(_run(ids, provider_config))
    return get_status()
