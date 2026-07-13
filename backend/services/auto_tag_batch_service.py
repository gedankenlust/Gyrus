"""
Bulk AI auto-tagging.

Runs the per-bookmark auto-tagger over a selected list of bookmark IDs in the
background, so the user can tag many (or all) bookmarks at once without freezing
the app. One run at a time, progress polled via BackgroundJob, cancellable.
Concurrency is deliberately modest — each tag means a local LLM call, and too
many in parallel would thrash Ollama / VRAM on smaller Macs.
"""
import asyncio

from database import SessionLocal
from services import bookmark_service
from services.background_job import BackgroundJob


# 3 parallel Ollama calls keeps Apple Silicon busy without thrashing. Higher
# values risk VRAM pressure / OOM on smaller Macs (16GB) with large models —
# Gyrus ships to all of them, so the default stays conservative.
CONCURRENCY = 3

job = BackgroundJob(processed=0, total=0, tagged=0, failed=0, created_tags=[])

get_status = job.get_status
is_running = job.is_running
cancel = job.cancel


async def _run(ids: list[str], provider_config: dict | None, language: str | None, job: BackgroundJob) -> None:
    from models.tag import Tag

    # Snapshot tag ids so we can report which tags the LLM *created* during
    # this run — the review sheet lets the user discard junk before it settles.
    db = SessionLocal()
    try:
        before = {t.id for t in db.query(Tag.id).all()}
    finally:
        db.close()

    sem = asyncio.Semaphore(CONCURRENCY)
    tagged = 0
    failed = 0

    async def tag_one(bm_id: str) -> None:
        nonlocal tagged, failed
        if job.cancelled:
            return
        async with sem:
            if job.cancelled:
                return
            # Each concurrent task gets its own session — a Session is not safe
            # to share across concurrent coroutines.
            db = SessionLocal()
            try:
                # Reuse cached Reader content and fetch it only when it is
                # missing. Titles alone are too ambiguous for reliable tags.
                await bookmark_service.auto_tag_bookmark(db, bm_id, provider_config, scrape=True, language=language)
                tagged += 1
            except Exception as e:
                # One failure (missing bookmark, LLM hiccup) must not abort the
                # batch — but don't fail silently: count it and keep the last
                # message so the UI can tell the user *why* (e.g. Ollama down)
                # instead of a misleading "tagged 0 of N".
                failed += 1
                job.state["error"] = str(e)
            finally:
                db.close()
        async with job.lock:
            job.state["processed"] += 1
            job.state["tagged"] = tagged
            job.state["failed"] = failed

    tasks = [asyncio.create_task(tag_one(i)) for i in ids]
    try:
        await asyncio.gather(*tasks, return_exceptions=True)
    except asyncio.CancelledError:
        pass  # still report what was created before the stop
    finally:
        # Plain assignments — safe even mid-cancellation (see BackgroundJob).
        job.state["tagged"] = tagged
        job.state["failed"] = failed
        db = SessionLocal()
        try:
            job.state["created_tags"] = [
                {"id": t.id, "name": t.name, "color": t.color}
                for t in db.query(Tag).filter(~Tag.id.in_(before)).all()
            ]
        finally:
            db.close()


async def start(ids: list[str], provider_config: dict | None = None, language: str | None = None) -> dict:
    if not ids:
        return await job.run_noop(reset={"total": 0})

    async def runner(job: BackgroundJob) -> None:
        await _run(ids, provider_config, language, job)

    return await job.start(runner, reset={"total": len(ids)})
