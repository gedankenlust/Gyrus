"""Pacing regressions using synthetic work; no model inference or real delays."""
import asyncio
import json
from unittest.mock import AsyncMock

import httpx
import pytest

from services import embedding_service, tagging_pacer


@pytest.mark.asyncio
@pytest.mark.parametrize('work,expected', [(0.1, 2), (10.5, 10.5), (360, 180)])
async def test_rest_tracks_work_with_countdown_and_resumes(monkeypatch, work, expected):
    now = 0.0
    pauses = []
    events = []
    async def sleep(seconds):
        nonlocal now
        pauses.append(seconds)
        now += seconds
    monkeypatch.setattr(tagging_pacer, 'monotonic', lambda: now)
    monkeypatch.setattr(tagging_pacer, 'sleep', sleep)
    await tagging_pacer.TaggingPacer(True, lambda *args: events.append(args)).rest(work, 'assigning')
    assert sum(pauses) == expected
    assert max(pauses) <= 1
    assert events[-1] == ('assigning', 0)
    assert all(stage == 'cooldown' for stage, _ in events[:-1])
    assert events[-2] == ('cooldown', 1)


@pytest.mark.asyncio
async def test_disabled_mode_neither_sleeps_nor_changes_progress(monkeypatch):
    sleep = AsyncMock()
    monkeypatch.setattr(tagging_pacer, 'sleep', sleep)
    events = []
    await tagging_pacer.TaggingPacer(False, lambda *args: events.append(args)).rest(180, 'embedding')
    sleep.assert_not_awaited()
    assert events == []


@pytest.mark.asyncio
async def test_stop_interrupts_rest_immediately():
    entered = asyncio.Event()
    events = []
    def progress(*args):
        events.append(args)
        entered.set()
    task = asyncio.create_task(tagging_pacer.TaggingPacer(True, progress).rest(180, 'assigning'))
    await asyncio.wait_for(entered.wait(), 1)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await asyncio.wait_for(task, 0.2)
    assert all(stage == 'cooldown' for stage, _ in events)


@pytest.mark.asyncio
async def test_embeddings_wait_for_rest_before_next_request(monkeypatch):
    events = []
    entered = asyncio.Event()
    resume = asyncio.Event()
    def handler(request):
        events.append('request')
        data = json.loads(request.content)
        return httpx.Response(200, json={'embeddings': [[1, 0] for _ in data['input']]})
    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    monkeypatch.setattr(embedding_service.httpx, 'AsyncClient', lambda **_: client)
    async def rest(seconds):
        assert seconds >= 0
        events.append('rest')
        entered.set()
        await resume.wait()
    task = asyncio.create_task(embedding_service.get_embeddings(
        ['Example'] * 33, progress=lambda *_: events.append('progress'), after_batch=rest,
    ))
    try:
        await asyncio.wait_for(entered.wait(), 1)
        assert events == ['request', 'progress', 'rest']
        resume.set()
        vectors = await asyncio.wait_for(task, 1)
        assert len(vectors) == 33
        assert events == ['request', 'progress', 'rest'] * 2
    finally:
        if not task.done():
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
