"""Search-index regressions for token-dense Reader content and Ollama errors."""
import json
from contextlib import contextmanager

import httpx
import pytest

from services import embedding_service, vector_store
from tests.test_meta_improvements import vectors  # noqa: F401


@pytest.mark.asyncio
async def test_long_unicode_text_uses_model_token_truncation(monkeypatch):
    text = '中文 🧪 αβγδ ' * 1200
    async def handler(request):
        payload = json.loads(request.content)
        assert request.url.path == '/api/embed'
        assert payload == {'model':'test', 'input':text[:8000], 'truncate':True}
        return httpx.Response(200, json={'embeddings':[[0.6, 0.8]]})
    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    monkeypatch.setattr(embedding_service.httpx, 'AsyncClient', lambda **_:client)
    assert await embedding_service.get_embedding(text, model='test') == [0.6, 0.8]


@pytest.mark.asyncio
@pytest.mark.parametrize('body', [None, {}, {'embeddings':[]}, {'embeddings':[[True]]},
                                       {'embeddings':[[float('nan')]]}, {'embeddings':[[1],[2]]}])
async def test_invalid_vectors_never_reach_index(monkeypatch, body):
    client = httpx.AsyncClient(transport=httpx.MockTransport(lambda _:httpx.Response(200, content=json.dumps(body))))
    monkeypatch.setattr(embedding_service.httpx, 'AsyncClient', lambda **_:client)
    with pytest.raises(embedding_service.EmbeddingUnavailableError) as error:
        await embedding_service.get_embedding('Example')
    assert error.value.code == 'embedding_invalid_response'


@pytest.mark.asyncio
@pytest.mark.parametrize('status,detail,code', [
    (500, 'input (2268 tokens) is too large to process. increase the physical batch size (current batch size: 2048)', 'embedding_input_too_long'),
    (500, 'internal failure with private submitted content', 'embedding_server_error'),
    (404, 'model not found', 'embedding_model_unavailable'),
])
async def test_server_errors_are_classified_without_exposing_raw_input(monkeypatch, status, detail, code):
    client = httpx.AsyncClient(transport=httpx.MockTransport(lambda _:httpx.Response(status, json={'error':detail})))
    monkeypatch.setattr(embedding_service.httpx, 'AsyncClient', lambda **_:client)
    with pytest.raises(embedding_service.EmbeddingUnavailableError) as error:
        await embedding_service.get_embedding('Example')
    assert error.value.code == code
    assert detail not in str(error.value)
    assert 'developer.mozilla.org' not in str(error.value)


def test_modern_vectors_cannot_be_mixed_into_legacy_index(monkeypatch, vectors):
    monkeypatch.setattr(embedding_service, '_active_model', 'model-a')
    monkeypatch.setattr(embedding_service, '_active_base_url', 'http://localhost:11434')
    legacy_key = json.dumps(['http://localhost:11434', 'model-a:latest'])
    vector_store.reset_table(3, legacy_key)
    vector_store.upsert('old', [0.1, 0.2, 0.3], model_key=legacy_key)
    assert not vector_store.matches_configuration(embedding_service.configuration_key())
    assert not vector_store.upsert('new', [0.2, 0.3, 0.4], model_key=embedding_service.configuration_key())
    assert vector_store.count() == 1


@pytest.mark.asyncio
@pytest.mark.parametrize('fail', [False, True])
async def test_reindex_handles_long_text_or_retains_old_index(db, monkeypatch, vectors, fail):
    import database
    from models.bookmark import Bookmark
    from routers import search
    from services import background
    db.add_all([Bookmark(id='a', title='Long', url='https://a.example', scraped_content='中文 🧪 ' * 1500),
                Bookmark(id='b', title='Short', url='https://b.example', scraped_content='Short text')])
    db.commit()
    @contextmanager
    def session(): yield db
    monkeypatch.setattr(database, 'SessionLocal', session)
    original_client = httpx.AsyncClient
    count = 0
    def handler(request):
        nonlocal count
        count += 1
        assert request.url.path == '/api/embed'
        assert json.loads(request.content)['truncate'] is True
        if fail and count == 2:
            return httpx.Response(500, json={'error':'internal error'})
        return httpx.Response(200, json={'embeddings':[[0.6, 0.8, 0.0]]})
    monkeypatch.setattr(embedding_service.httpx, 'AsyncClient', lambda **_:original_client(transport=httpx.MockTransport(handler)))
    await search.reindex_embeddings(db)
    await background.drain()
    assert not search._reindex_running
    if fail:
        assert search._progress()['reindex_error_code'] == 'embedding_server_error'
        assert search._reindex_completed == 1
        assert vector_store.matches_configuration('model-a')
        assert vector_store.count() == 1
    else:
        assert search._reindex_error is None
        assert search._progress()['reindex_error_code'] is None
        assert search._reindex_completed == 2
        assert vector_store.matches_configuration(embedding_service.configuration_key())
        assert vector_store.count() == 2
