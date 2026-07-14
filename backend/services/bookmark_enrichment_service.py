"""Post-save bookmark enrichment.

Extension saves must feel instant. The work that makes a bookmark useful in
Gyrus (metadata, Reader text, semantic index, first-pass tags, design snapshot)
belongs in a bounded background pipeline instead of the request/response path.
"""
from __future__ import annotations

import asyncio
import logging

from database import SessionLocal
from models.bookmark import Bookmark
from services import (
    bookmark_service,
    metadata_service,
    visual_snapshot_service,
)

logger = logging.getLogger(__name__)

_reader_semaphore = asyncio.Semaphore(3)
_snapshot_semaphore = asyncio.Semaphore(1)


async def enrich_bookmark(bookmark_id: str, *, include_design_snapshot: bool = False) -> None:
    """Best-effort post-create enrichment.

    Nothing here may break the original bookmark save. Failures are logged and
    the user can still manually re-run metadata, Reader, tags, or Design later.
    """
    async with _reader_semaphore:
        db = SessionLocal()
        try:
            bm = db.query(Bookmark).filter(Bookmark.id == bookmark_id).first()
            if not bm or bm.deleted_at is not None:
                return
            url = bm.url
            title = bm.title

            try:
                meta = await metadata_service.fetch_metadata(url)
                bm = bookmark_service.update_bookmark_metadata(db, bm, meta)
            except Exception as exc:
                logger.info("metadata enrichment skipped for %s: %s", bookmark_id, exc)

            content = (bm.scraped_content or "").strip()
            if not content:
                try:
                    from services.scraper_service import scraper_service
                    scrape_result = await scraper_service.extract_content(url)
                    content = (scrape_result.get("content") or "").strip()
                    if content:
                        bookmark_service.store_scraped_content(db, bookmark_id, content)
                        db.refresh(bm)
                        title = scrape_result.get("title") or title
                        from services import background
                        background.schedule(bookmark_service.index_bookmark_embedding(bookmark_id, content))
                except Exception as exc:
                    logger.info("reader enrichment skipped for %s: %s", bookmark_id, exc)

            try:
                bookmark_service.apply_fast_auto_tags(db, bm, content=content, limit=3)
            except Exception as exc:
                logger.info("fast auto-tagging skipped for %s: %s", bookmark_id, exc)
        finally:
            db.close()

    if include_design_snapshot:
        async with _snapshot_semaphore:
            try:
                # Skip work if the user already inspected this page.
                _, complete = visual_snapshot_service.snapshot_summary(bookmark_id)
                if complete:
                    return
                await visual_snapshot_service.capture_snapshot(bookmark_id, url, title=title)
            except Exception as exc:
                logger.info("design snapshot enrichment skipped for %s: %s", bookmark_id, exc)
