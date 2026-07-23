"""Durable, bounded post-save bookmark enrichment."""
from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timezone
from sqlalchemy.orm import Session

from database import SessionLocal
from models.bookmark import Bookmark
from services import bookmark_service, metadata_service, visual_snapshot_service

logger = logging.getLogger(__name__)

_pipeline_semaphore = asyncio.Semaphore(3)
_index_semaphore = asyncio.Semaphore(1)
_snapshot_semaphore = asyncio.Semaphore(1)
_active_ids: set[str] = set()
_active_lock = asyncio.Lock()
_index_active_ids: set[str] = set()
_index_active_lock = asyncio.Lock()


def _now() -> datetime:
    return datetime.now(timezone.utc)


def analysis_summary(bookmark: Bookmark, *, design_captured: bool, design_complete: bool) -> dict:
    """Build the stable API representation from persisted stage states."""
    stages = (bookmark.metadata_status, bookmark.reader_status)
    core = set(stages)
    if "running" in core:
        overall = "running"
    elif "pending" in core:
        overall = "pending"
    elif core == {"ready"}:
        overall = "ready"
    elif "failed" in core:
        overall = "partial" if "ready" in core else "failed"
    else:
        # A legacy bookmark may already have metadata while Reader analysis
        # was never requested. That is incomplete, not an error.
        overall = "not_requested"

    design = "ready" if design_complete else ("stale" if design_captured else "not_requested")
    return {
        "overall": overall,
        "metadata": bookmark.metadata_status,
        "reader": bookmark.reader_status,
        "index": bookmark.index_status,
        "design": design,
        "last_error": bookmark.analysis_error,
        "attempts": bookmark.analysis_attempts,
        "updated_at": bookmark.analysis_updated_at,
    }


def _apply_stage(
    bookmark: Bookmark,
    stage: str,
    status: str,
    error: str | None = None,
) -> None:
    setattr(bookmark, f"{stage}_status", status)
    bookmark.analysis_updated_at = _now()
    if error:
        bookmark.analysis_error = error[:1_000]
    elif (
        status == "ready"
        and bookmark.metadata_status != "failed"
        and bookmark.reader_status != "failed"
    ):
        bookmark.analysis_error = None

    # Once Reader text is durable, semantic indexing is real pending work.
    # Persisting this transition closes the restart gap between extraction and
    # the asynchronous Ollama request.
    if (
        stage == "reader"
        and status == "ready"
        and bookmark.index_status != "ready"
    ):
        bookmark.index_status = "pending"


def _set_stage(bookmark_id: str, stage: str, status: str, error: str | None = None) -> None:
    db = SessionLocal()
    try:
        bookmark = db.query(Bookmark).filter(Bookmark.id == bookmark_id).first()
        if bookmark is None:
            return
        _apply_stage(bookmark, stage, status, error)
        db.commit()
    except Exception:
        db.rollback()
        logger.exception("Could not persist %s status for bookmark %s", stage, bookmark_id)
    finally:
        db.close()


def record_stage(
    bookmark_id: str,
    stage: str,
    status: str,
    error: str | None = None,
    db: Session | None = None,
) -> None:
    """Persist a stage completed through a user-triggered endpoint."""
    if stage not in {"metadata", "reader", "index"}:
        raise ValueError(f"Unknown enrichment stage: {stage}")
    if db is None:
        _set_stage(bookmark_id, stage, status, error)
        return
    bookmark = db.query(Bookmark).filter(Bookmark.id == bookmark_id).first()
    if bookmark is None:
        return
    _apply_stage(bookmark, stage, status, error)
    db.commit()


def _prepare_attempt(bookmark_id: str) -> tuple[str, str, str, str] | None:
    db = SessionLocal()
    try:
        bookmark = db.query(Bookmark).filter(Bookmark.id == bookmark_id).first()
        if bookmark is None or bookmark.deleted_at is not None:
            return None
        bookmark.analysis_attempts += 1
        bookmark.analysis_error = None
        bookmark.analysis_updated_at = _now()
        db.commit()
        return (
            bookmark.url,
            bookmark.title,
            (bookmark.scraped_content or "").strip(),
            bookmark.metadata_status,
        )
    finally:
        db.close()


def schedule_enrichment(bookmark_id: str, *, include_design_snapshot: bool = False) -> None:
    """Queue enrichment from request workers without blocking the response."""
    from services import background

    background.schedule(enrich_bookmark(bookmark_id, include_design_snapshot=include_design_snapshot))


def schedule_index(bookmark_id: str, content: str) -> None:
    """Queue semantic indexing independently from the extraction pipeline."""
    from services import background

    background.schedule(index_bookmark(bookmark_id, content))


async def index_bookmark(bookmark_id: str, content: str) -> None:
    """Index one bookmark once without losing Reader-triggered work."""
    if not content.strip():
        return
    async with _index_active_lock:
        if bookmark_id in _index_active_ids:
            return
        _index_active_ids.add(bookmark_id)

    try:
        async with _index_semaphore:
            _set_stage(bookmark_id, "index", "running")
            indexed = await bookmark_service.index_bookmark_embedding(bookmark_id, content)
            _set_stage(bookmark_id, "index", "ready" if indexed else "unavailable")
    finally:
        async with _index_active_lock:
            _index_active_ids.discard(bookmark_id)


async def enrich_bookmark(bookmark_id: str, *, include_design_snapshot: bool = False) -> None:
    """Enrich one bookmark once, persisting every stage transition."""
    async with _active_lock:
        if bookmark_id in _active_ids:
            return
        _active_ids.add(bookmark_id)

    try:
        async with _pipeline_semaphore:
            prepared = _prepare_attempt(bookmark_id)
            if prepared is None:
                return
            url, title, content, metadata_status = prepared

            if metadata_status != "ready":
                _set_stage(bookmark_id, "metadata", "running")
                try:
                    meta = await metadata_service.fetch_metadata(url)
                    db = SessionLocal()
                    try:
                        bookmark = db.query(Bookmark).filter(Bookmark.id == bookmark_id).first()
                        if bookmark is not None:
                            bookmark_service.update_bookmark_metadata(db, bookmark, meta)
                    finally:
                        db.close()
                    _set_stage(bookmark_id, "metadata", "ready")
                except Exception as exc:
                    logger.warning("Metadata enrichment failed for %s: %s", bookmark_id, exc)
                    _set_stage(bookmark_id, "metadata", "failed", f"Metadata: {exc}")

            if content:
                _set_stage(bookmark_id, "reader", "ready")
            else:
                _set_stage(bookmark_id, "reader", "running")
                try:
                    from services.scraper_service import scraper_service

                    scrape_result = await scraper_service.extract_content(url)
                    content = (scrape_result.get("content") or "").strip()
                    if not content:
                        raise ValueError("No readable page text found")
                    db = SessionLocal()
                    try:
                        if not bookmark_service.store_scraped_content(db, bookmark_id, content):
                            raise RuntimeError("Reader text could not be stored")
                    finally:
                        db.close()
                    _set_stage(bookmark_id, "reader", "ready")
                except Exception as exc:
                    logger.warning("Reader enrichment failed for %s: %s", bookmark_id, exc)
                    _set_stage(bookmark_id, "reader", "failed", f"Reader: {exc}")
                    content = ""

        if content:
            await index_bookmark(bookmark_id, content)

        if include_design_snapshot:
            async with _snapshot_semaphore:
                try:
                    _, complete = visual_snapshot_service.snapshot_summary(bookmark_id)
                    if not complete:
                        await visual_snapshot_service.capture_snapshot(bookmark_id, url, title=title)
                except Exception as exc:
                    logger.warning("Design snapshot enrichment failed for %s: %s", bookmark_id, exc)
    finally:
        async with _active_lock:
            _active_ids.discard(bookmark_id)


def retry(bookmark_id: str) -> bool:
    """Reset failed/missing core stages and queue another attempt."""
    db = SessionLocal()
    try:
        bookmark = db.query(Bookmark).filter(
            Bookmark.id == bookmark_id, Bookmark.deleted_at.is_(None)
        ).first()
        if bookmark is None:
            return False
        if bookmark.metadata_status != "ready":
            bookmark.metadata_status = "pending"
        if bookmark.reader_status != "ready":
            bookmark.reader_status = "pending"
        if bookmark.index_status != "ready":
            bookmark.index_status = "not_requested"
        bookmark.analysis_error = None
        bookmark.analysis_updated_at = _now()
        db.commit()
    finally:
        db.close()
    schedule_enrichment(bookmark_id)
    return True


def resume_pending() -> int:
    """Resume jobs interrupted by an app/backend shutdown."""
    db = SessionLocal()
    try:
        bookmarks = db.query(Bookmark).filter(
            Bookmark.deleted_at.is_(None),
            (Bookmark.metadata_status.in_(("pending", "running")))
            | (Bookmark.reader_status.in_(("pending", "running")))
            | (Bookmark.index_status.in_(("pending", "running"))),
        ).all()
        ids = [bookmark.id for bookmark in bookmarks]
        for bookmark in bookmarks:
            if bookmark.metadata_status == "running":
                bookmark.metadata_status = "pending"
            if bookmark.reader_status == "running":
                bookmark.reader_status = "pending"
            if bookmark.index_status == "running":
                bookmark.index_status = "pending"
        db.commit()
    finally:
        db.close()

    for bookmark_id in ids:
        schedule_enrichment(bookmark_id)
    return len(ids)
