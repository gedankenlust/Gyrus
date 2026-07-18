"""Global taxonomy background job: progress, missing rows, and lifecycle."""
import asyncio
import uuid
from unittest.mock import AsyncMock, patch

import pytest

from database import SessionLocal
from models.bookmark import Bookmark
from services import auto_tag_batch_service


async def _wait_until_done(timeout: float = 5.0) -> None:
    elapsed = 0.0
    while auto_tag_batch_service.is_running() and elapsed < timeout:
        await asyncio.sleep(0.05)
        elapsed += 0.05


def _bookmarks(count: int) -> list[str]:
    db = SessionLocal()
    ids: list[str] = []
    try:
        for index in range(count):
            bookmark = Bookmark(
                title=f"Taxonomy test {uuid.uuid4()}",
                url=f"https://taxonomy-{uuid.uuid4()}.example/{index}",
                scraped_content="Enough cached content for the taxonomy.",
            )
            db.add(bookmark)
            db.flush()
            ids.append(bookmark.id)
        db.commit()
        return ids
    finally:
        db.close()


def _draft(ids: list[str]) -> dict:
    return {
        "id": str(uuid.uuid4()), "language": "en", "total": len(ids),
        "assigned": len(ids), "without_tags": 0,
        "tags": [{
            "id": "T001", "name": "testing", "bookmark_ids": ids,
            "bookmark_titles": ["Test"] * len(ids), "bookmark_count": len(ids),
        }],
        "untagged": [],
    }


@pytest.mark.asyncio
async def test_batch_builds_one_review_draft_without_writing_tags():
    ids = _bookmarks(3)
    async def generate(db, bookmarks, config, language, progress=None):
        assert progress is not None
        progress("organizing", 42)
        return _draft(ids)

    generator = AsyncMock(side_effect=generate)
    with patch("services.taxonomy_service.generate_draft", new=generator):
        await auto_tag_batch_service.start(ids, None)
        await _wait_until_done()

    status = auto_tag_batch_service.get_status()
    assert status["total"] == 3
    assert status["processed"] == 3
    assert status["assigned"] == 3
    assert status["failed"] == 0
    assert status["phase"] == "review"
    assert status["generated_tokens"] == 42
    assert status["draft"]["tags"][0]["name"] == "testing"
    generator.assert_awaited_once()


@pytest.mark.asyncio
async def test_discard_draft_clears_visible_job_status():
    ids = _bookmarks(2)
    draft = _draft(ids)
    generator = AsyncMock(return_value=draft)
    with patch("services.taxonomy_service.generate_draft", new=generator):
        await auto_tag_batch_service.start(ids, None)
        await _wait_until_done()

    auto_tag_batch_service.discard_draft(draft["id"])

    status = auto_tag_batch_service.get_status()
    assert status["draft"] is None
    assert status["assigned"] == 0
    assert status["without_tags"] == 2
    assert status["phase"] == "idle"


@pytest.mark.asyncio
async def test_batch_reports_missing_bookmark_and_uses_valid_rows():
    ids = _bookmarks(2)
    requested = [ids[0], "missing", ids[1]]
    generator = AsyncMock(return_value=_draft(ids))
    with patch("services.taxonomy_service.generate_draft", new=generator):
        await auto_tag_batch_service.start(requested, None)
        await _wait_until_done()

    status = auto_tag_batch_service.get_status()
    assert status["processed"] == 3
    assert status["failed"] == 1
    assert status["assigned"] == 2
    assert status["running"] is False


@pytest.mark.asyncio
async def test_batch_with_no_ids_finishes_immediately():
    status = await auto_tag_batch_service.start([], None)
    assert status["total"] == 0
    assert status["running"] is False


def test_taxonomy_rejects_tiny_selections_before_any_llm_work(client):
    # One bookmark can never yield shared categories — fail fast, localized.
    resp = client.post("/api/bookmarks/auto-tag-batch", json={
        "bookmark_ids": ["only-one"], "language": "de",
    })
    assert resp.status_code == 422
    assert "mindestens 10 Lesezeichen" in resp.json()["detail"]

    resp = client.post("/api/bookmarks/auto-tag-batch", json={
        "bookmark_ids": [f"bm{i}" for i in range(9)], "language": "en",
    })
    assert resp.status_code == 422
    assert "at least 10 bookmarks" in resp.json()["detail"]
