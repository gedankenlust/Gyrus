"""Bulk auto-tag background job: progress accounting and lifecycle."""
import asyncio

import pytest
from unittest.mock import AsyncMock, patch

from services import auto_tag_batch_service


async def _wait_until_done(timeout: float = 5.0) -> None:
    elapsed = 0.0
    while auto_tag_batch_service.is_running() and elapsed < timeout:
        await asyncio.sleep(0.05)
        elapsed += 0.05


@pytest.mark.asyncio
async def test_batch_tags_every_id_and_reports_counts():
    # Mock the per-bookmark tagger so the test needs neither Ollama nor scraping.
    with patch("services.bookmark_service.auto_tag_bookmark", new=AsyncMock(return_value=None)):
        await auto_tag_batch_service.start(["a", "b", "c"], None)
        await _wait_until_done()

    status = auto_tag_batch_service.get_status()
    assert status["total"] == 3
    assert status["processed"] == 3
    assert status["tagged"] == 3
    assert status["running"] is False


@pytest.mark.asyncio
async def test_batch_survives_a_failing_bookmark():
    # One bookmark raises; the batch must keep going and not count it as tagged.
    calls = {"n": 0}

    async def flaky(db, bm_id, cfg):
        calls["n"] += 1
        if bm_id == "boom":
            raise RuntimeError("LLM hiccup")

    with patch("services.bookmark_service.auto_tag_bookmark", new=AsyncMock(side_effect=flaky)):
        await auto_tag_batch_service.start(["ok1", "boom", "ok2"], None)
        await _wait_until_done()

    status = auto_tag_batch_service.get_status()
    assert status["processed"] == 3      # all attempted
    assert status["tagged"] == 2         # only the two that succeeded
    assert status["running"] is False


@pytest.mark.asyncio
async def test_batch_with_no_ids_finishes_immediately():
    status = await auto_tag_batch_service.start([], None)
    assert status["total"] == 0
    assert status["running"] is False
