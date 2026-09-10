"""Large-library regressions; synthetic records and local mock services only."""
import asyncio
import json
from unittest.mock import AsyncMock

import httpx
import pytest
from sqlalchemy.orm import sessionmaker

from models.bookmark import Bookmark
from services import ai_policy, embedding_service, metadata_refresh_service as refresh
from services import taxonomy_service, taxonomy_checkpoint, auto_tag_batch_service
from services.background_job import BackgroundJob


@pytest.mark.asyncio
async def test_metadata_timeout_does_not_stall_workers_and_progress_is_durable(db, engine, monkeypatch):
    db.add_all([Bookmark(id=i, title=i, url=f"https://{i}.example") for i in ['fast', 'slow', 'trash']])
    from datetime import datetime, timezone
    db.get(Bookmark, 'trash').deleted_at = datetime.now(timezone.utc)
    db.commit()
    monkeypatch.setattr(refresh, 'SessionLocal', sessionmaker(bind=engine))
    monkeypatch.setattr(refresh, 'ITEM_TIMEOUT', 0.1)
    fast_saved = asyncio.Event()
    original_save = refresh._save_result
    loop = asyncio.get_running_loop()

    def save(id_, meta):
        value = original_save(id_, meta)
        if id_ == 'fast':
            loop.call_soon_threadsafe(fast_saved.set)
        return value

    async def fetch(url):
        if 'slow' in url:
            await asyncio.Event().wait()
        assert 'trash' not in url
        return {'description': 'Saved immediately'}

    monkeypatch.setattr(refresh, '_save_result', save)
    monkeypatch.setattr(refresh.metadata_service, 'fetch_metadata', fetch)
    job = BackgroundJob(processed=0, total=0, updated=0, failed=0)
    await job.start(refresh._run_refresh)
    await asyncio.wait_for(fast_saved.wait(), 1)
    db.expire_all()
    assert db.get(Bookmark, 'fast').description == 'Saved immediately'
    assert job.is_running()
    await asyncio.wait_for(job._task, 2)
    assert job.state['processed'] == job.state['total'] == 2
    assert job.state['updated'] == 1
    assert job.state['failed'] == 1
    assert job.state['error'] is None


@pytest.mark.asyncio
async def test_metadata_cancellation_keeps_completed_work(monkeypatch):
    monkeypatch.setattr(refresh, '_rows', lambda: [('fast', 'fast'), ('slow', 'slow')])
    saved = []
    monkeypatch.setattr(refresh, '_save_result', lambda id_, meta: saved.append(id_) or 1)
    async def fetch(url):
        if url == 'slow':
            await asyncio.Event().wait()
        return {'description': 'Kept'}
    monkeypatch.setattr(refresh.metadata_service, 'fetch_metadata', fetch)
    job = BackgroundJob(processed=0, total=0, updated=0, failed=0)
    await job.start(refresh._run_refresh)
    async with asyncio.timeout(2):
        while job.state['processed'] < 1:
            await asyncio.sleep(0.001)
    job.cancel()
    await asyncio.wait_for(job._task, 1)
    assert saved == ['fast']
    assert job.state['updated'] == job.state['processed'] == 1
    assert not job.is_running()


@pytest.mark.asyncio
async def test_metadata_4000_items_use_bounded_workers(monkeypatch):
    monkeypatch.setattr(refresh, '_rows', lambda: [(str(i), str(i)) for i in range(4000)])
    monkeypatch.setattr(refresh, '_save_result', lambda *_: 1)
    active = peak = 0
    async def fetch(url):
        nonlocal active, peak
        active += 1
        peak = max(peak, active)
        await asyncio.sleep(0)
        active -= 1
        return {'description': 'Example'}
    monkeypatch.setattr(refresh.metadata_service, 'fetch_metadata', fetch)
    job = BackgroundJob(processed=0, total=0, updated=0, failed=0)
    await job.start(refresh._run_refresh)
    await asyncio.wait_for(job._task, 10)
    assert job.state['processed'] == job.state['updated'] == 4000
    assert peak <= refresh.CONCURRENCY
    assert job.state['error'] is None


@pytest.mark.asyncio
async def test_embeddings_are_ordered_bounded_and_report_progress(monkeypatch):
    payloads = []
    async def handler(request):
        payload = json.loads(request.content)
        payloads.append(payload)
        return httpx.Response(200, json={'embeddings': [[float(text), 1.0] for text in payload['input']]})
    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    monkeypatch.setattr(embedding_service.httpx, 'AsyncClient', lambda **_: client)
    progress = []
    vectors = await embedding_service.get_embeddings([str(i) for i in range(4094)], progress=lambda n, total: progress.append((n,total)))
    assert [v[0] for v in vectors] == list(range(4094))
    assert max(len(p['input']) for p in payloads) <= 32
    assert all(p['keep_alive'] == '5m' for p in payloads[:-1])
    assert payloads[-1]['keep_alive'] == 0
    assert progress[-1] == (4094, 4094)
    assert len(progress) == len(payloads) == 128


@pytest.mark.asyncio
async def test_embedding_policy_change_stops_before_next_batch(monkeypatch):
    count = 0
    async def handler(request):
        nonlocal count
        count += 1
        data = json.loads(request.content)
        return httpx.Response(200, json={'embeddings': [[1, 0] for _ in data['input']]})
    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    monkeypatch.setattr(embedding_service.httpx, 'AsyncClient', lambda **_: client)
    with pytest.raises(embedding_service.EmbeddingUnavailableError, match='configuration changed'):
        await embedding_service.get_embeddings(['text'] * 65, progress=lambda *_: ai_policy.configure(False))
    assert count == 1


def test_classification_row_format_accepts_bookmarks_above_999():
    parsed = taxonomy_service._classification_payload(json.dumps([
        {'id': 'B999', 'tag': 'design'}, {'id': 'B1000', 'tag': 'audio'}, {'id': 'B4094', 'tag': 'ki'}
    ]))
    assert parsed['B1000'] == 'audio'
    assert parsed['B4094'] == 'ki'


@pytest.mark.asyncio
async def test_tagging_uses_saved_records_without_scraping(db, engine, monkeypatch):
    from services.scraper_service import scraper_service
    db.add(Bookmark(id='cached', title='Useful saved title', url='https://example.com', description='Existing description'))
    db.commit()
    monkeypatch.setattr(auto_tag_batch_service, 'SessionLocal', sessionmaker(bind=engine))
    scrape = AsyncMock(side_effect=AssertionError('No page fetch expected'))
    monkeypatch.setattr(scraper_service, 'extract_content', scrape)
    async def generate(db, bookmarks, *_args, progress):
        assert bookmarks[0].description == 'Existing description'
        progress('embedding', 0)
        progress('embedded', 1)
        progress('assigning', 0)
        progress('classified', 1)
        return {'assigned': 1, 'without_tags': 0}
    monkeypatch.setattr(taxonomy_service, 'generate_draft', generate)
    job = BackgroundJob(processed=0, total=1, failed=0)
    await auto_tag_batch_service._run(['cached'], None, None, job)
    scrape.assert_not_awaited()
    assert job.state['embedded'] == job.state['classified'] == 1


@pytest.mark.asyncio
@pytest.mark.parametrize('failure', ['provider', 'timeout'])
async def test_retry_reuses_completed_classification_batches(db, monkeypatch, tmp_path, failure):
    monkeypatch.setattr(taxonomy_checkpoint, 'CHECKPOINT_DIR', tmp_path/'checkpoints')
    monkeypatch.setattr(taxonomy_service, 'CLASSIFICATION_BATCH_SIZE', 2)
    monkeypatch.setattr(taxonomy_service, 'CLASSIFICATION_TIMEOUT', 0.05)
    monkeypatch.setattr(taxonomy_service, '_classification_catalog', lambda *_: {'design': 'design', 'audio': 'audio', 'ki': 'AI'})
    async def embeddings(texts, **_):
        return [[1.0, 0.0] for _ in texts]
    monkeypatch.setattr(embedding_service, 'get_embeddings', embeddings)
    bookmarks = [Bookmark(id=str(i), title=f'Example {i}', url=f'https://example.com/{i}') for i in range(6)]
    calls = []
    fail = True
    async def stream(prompt, records, config, language, stage, progress, schema):
        keys = schema['required']
        calls.append(keys[0])
        if fail and keys[0] == 'B003':
            if failure == 'timeout':
                await asyncio.Event().wait()
            raise taxonomy_service.llm_service.LLMUnavailableError('Temporary timeout')
        label = {'B001':'design', 'B003':'audio', 'B005':'ki'}[keys[0]]
        return json.dumps({key: label for key in keys})
    monkeypatch.setattr(taxonomy_service, '_stream_taxonomy', stream)
    with pytest.raises(taxonomy_service.llm_service.LLMUnavailableError, match='2/6'):
        await taxonomy_service.generate_draft(db, bookmarks, {'model':'test'}, 'de')
    assert calls == ['B001', 'B003', 'B003']
    checkpoint = next((tmp_path/'checkpoints').glob('*.json'))
    assert checkpoint.stat().st_mode & 0o777 == 0o600
    fail = False
    calls.clear()
    draft = await taxonomy_service.generate_draft(db, bookmarks, {'model':'test'}, 'de')
    assert calls == ['B003', 'B005']
    assert draft['assigned'] == 6
    assert not checkpoint.exists()


@pytest.mark.asyncio
async def test_cancelling_gentle_pause_keeps_checkpoint_and_resume_skips_work(db, monkeypatch, tmp_path):
    from services import tagging_pacer
    monkeypatch.setattr(taxonomy_checkpoint, 'CHECKPOINT_DIR', tmp_path/'checkpoints')
    monkeypatch.setattr(taxonomy_service, 'CLASSIFICATION_BATCH_SIZE', 2)
    monkeypatch.setattr(taxonomy_service, '_classification_catalog', lambda *_: {'design':'design', 'audio':'audio', 'ki':'AI'})
    monkeypatch.setattr(embedding_service, 'get_embeddings', AsyncMock(return_value=[[1.0, 0.0]] * 9))
    calls = []
    async def stream(prompt, records, config, language, stage, progress, schema):
        keys = schema['required']
        calls.append(keys[0])
        label = {'B001':'design', 'B003':'audio', 'B005':'ki'}[keys[0]]
        return json.dumps({key: label for key in keys})
    monkeypatch.setattr(taxonomy_service, '_stream_taxonomy', stream)
    bookmarks = [Bookmark(id=str(i), title=f'Example {i}', url=f'https://example.com/{i}') for i in range(6)]
    paused = asyncio.Event()
    async def sleep(_):
        paused.set()
        await asyncio.Event().wait()
    monkeypatch.setattr(tagging_pacer, 'sleep', sleep)
    events = []
    task = asyncio.create_task(taxonomy_service.generate_draft(
        db, bookmarks, {'model':'test', 'gentle_tagging':True}, 'de',
        progress=lambda *args: events.append(args),
    ))
    try:
        await asyncio.wait_for(paused.wait(), 1)
        assert calls == ['B001']
        assert ('classified', 2) in events
        assert events[-1][0] == 'cooldown'
        assert len(list((tmp_path/'checkpoints').glob('*.json'))) == 1
    finally:
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
    # Switching off gentle mode must preserve completed work and avoid resting.
    calls.clear()
    draft = await asyncio.wait_for(taxonomy_service.generate_draft(
        db, bookmarks, {'model':'test', 'gentle_tagging':False}, 'de',
    ), 1)
    assert calls == ['B003', 'B005']
    assert draft['assigned'] == 6
    assert not list((tmp_path/'checkpoints').glob('*.json'))


@pytest.mark.asyncio
async def test_metadata_stop_waits_for_inflight_commit(monkeypatch):
    import threading
    started = threading.Event()
    finish = threading.Event()
    monkeypatch.setattr(refresh, '_rows', lambda: [('one', 'one'), ('two', 'two')])
    def save(*_):
        started.set()
        assert finish.wait(2)
        return 1
    monkeypatch.setattr(refresh, '_save_result', save)
    monkeypatch.setattr(refresh.metadata_service, 'fetch_metadata', AsyncMock(return_value={'description':'Kept'}))
    job = BackgroundJob(processed=0, total=0, updated=0, failed=0)
    await job.start(refresh._run_refresh)
    async with asyncio.timeout(2):
        while not started.is_set():
            await asyncio.sleep(0.001)
    job.cancel()
    await asyncio.sleep(0.01)
    assert job.is_running(), 'Job must retain its maintenance lock until the write ends'
    finish.set()
    await asyncio.wait_for(job._task, 1)
    assert job.state['processed'] == job.state['updated'] == 1
    assert not job.is_running()


def test_incomplete_classification_requires_repair():
    with pytest.raises(taxonomy_service.TaxonomyQualityError, match='omitted'):
        taxonomy_service._checked_classification('{"B001":"design"}', ['B001','B002'])


@pytest.mark.asyncio
async def test_metadata_service_keeps_partial_result_at_total_deadline(monkeypatch):
    from services import metadata_service
    from contextlib import asynccontextmanager
    @asynccontextmanager
    async def proxy(**_):
        from types import SimpleNamespace
        yield SimpleNamespace(url='http://proxy.test')
    monkeypatch.setattr(metadata_service, 'SafeEgressProxy', proxy)
    monkeypatch.setattr(metadata_service, 'TOTAL_TIMEOUT', 0.25)
    monkeypatch.setattr(metadata_service, 'get_limited', AsyncMock(return_value=httpx.Response(
        200, text='<html><meta name="description" content="Keep this description"></html>',
        request=httpx.Request('GET', 'https://example.com')
    )))
    async def hung_favicon(*_):
        await asyncio.Event().wait()
    monkeypatch.setattr(metadata_service, '_fetch_favicon', hung_favicon)
    result = await asyncio.wait_for(metadata_service.fetch_metadata('https://example.com'), 1)
    assert result['description'] == 'Keep this description'


@pytest.mark.asyncio
async def test_ollama_stream_error_is_reported_instead_of_empty_classification(monkeypatch):
    from services.llm_service import LLMService, LLMUnavailableError
    from services import llm_service
    client = httpx.AsyncClient(transport=httpx.MockTransport(lambda request: httpx.Response(
        200, text='{"error":"model requires more memory"}\n'
    )))
    monkeypatch.setattr(llm_service, '_get_client', lambda: client)
    try:
        with pytest.raises(LLMUnavailableError, match='more memory'):
            _ = [part async for part in LLMService.stream_ollama('prompt', 'context', {'model':'test'})]
    finally:
        await client.aclose()
