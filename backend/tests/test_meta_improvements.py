"""Data-loss, protocol and index regressions from the September meta-review."""
import asyncio
import json

import pytest
from fastapi import FastAPI, Request
from fastapi.testclient import TestClient

from tests.test_stabilization import migrated, migrated_client  # noqa: F401
from services import ai_policy, vector_store


def envelope(**changes):
    return dict(version=1, collections=[], tags=[], bookmarks=[], **changes)


@pytest.mark.parametrize('payload', [{}, {'hello': 'world'}, {'bookmarks': []},
                                     {'version': True, 'collections': [], 'tags': [], 'bookmarks': []}])
def test_unrelated_json_cannot_replace_library(migrated_client, payload):
    c = migrated_client
    saved = c.post('/api/bookmarks', json={'title': 'Keep', 'url': 'https://keep.example'}).json()
    assert c.post('/api/data/restore/preview', json=payload).status_code == 422
    assert c.post('/api/data/restore', json=payload).status_code == 422
    assert c.get('/api/bookmarks/' + saved['id']).status_code == 200


def test_restore_preview_and_safety_copy(migrated_client, monkeypatch, tmp_path):
    from services import backup_service
    monkeypatch.setattr(backup_service, 'BACKUP_DIR', tmp_path)
    c = migrated_client
    saved = c.post('/api/bookmarks', json={'title': 'Keep', 'url': 'https://keep.example'}).json()
    preview = c.post('/api/data/restore/preview', json=envelope())
    assert preview.status_code == 200
    assert preview.json()['bookmarks'] == 0
    assert c.get('/api/bookmarks/' + saved['id']).status_code == 200
    assert c.post('/api/data/restore', json=envelope()).status_code == 200
    copies = list(tmp_path.glob('gyrus-prerestore-*.json'))
    assert len(copies) == 1
    assert json.loads(copies[0].read_text())['bookmarks'][0]['id'] == saved['id']
    assert copies[0].stat().st_mode & 0o777 == 0o600


def test_restore_aborts_if_safety_copy_fails(migrated_client, monkeypatch):
    from services import backup_service
    def fail(_):
        raise OSError('disk full')
    monkeypatch.setattr(backup_service, 'save_before_restore', fail)
    c = migrated_client
    saved = c.post('/api/bookmarks', json={'title': 'Keep', 'url': 'https://keep.example'}).json()
    assert c.post('/api/data/restore', json=envelope()).status_code == 503
    assert c.get('/api/bookmarks/' + saved['id']).status_code == 200


def test_legacy_names_and_deep_folders_round_trip(migrated_client):
    payload = envelope()
    payload['collections'] = [dict(id=f'f{i}', name=(' ' if i == 0 else 'x' * 300),
                                       parent_id=f'f{i-1}' if i else None) for i in range(65)]
    c = migrated_client
    assert c.post('/api/data/restore', json=payload).status_code == 200
    restored = c.get('/api/data/backup').json()
    assert len(restored['collections']) == 65
    assert {row['name'] for row in restored['collections']} == {' ', 'x' * 300}
    assert c.post('/api/data/restore', json=restored).status_code == 200
    assert c.get('/api/collections').status_code == 200


@pytest.mark.parametrize('name', ['', '   ', 'x' * 256, None])
def test_new_folder_names_are_validated(migrated_client, name):
    assert migrated_client.post('/api/collections', json={'name': name}).status_code == 422


def test_folder_conflicts_parent_and_depth(migrated_client):
    c = migrated_client
    root = c.post('/api/collections', json={'name': 'Root'}).json()['id']
    assert c.post('/api/collections', json={'name': 'Root'}).status_code == 409
    assert c.post('/api/collections', json={'name': 'Missing', 'parent_id': 'missing'}).status_code == 404
    assert c.put('/api/collections/' + root, json={'name': None}).status_code == 422
    parent = root
    for depth in range(2, 65):
        response = c.post('/api/collections', json={'name': str(depth), 'parent_id': parent})
        assert response.status_code == 201
        parent = response.json()['id']
    assert c.post('/api/collections', json={'name': 'Too deep', 'parent_id': parent}).status_code == 422
    sibling = c.post('/api/collections', json={'name': 'Sibling'}).json()['id']
    c.post('/api/collections', json={'name': 'Child', 'parent_id': sibling})
    assert c.put('/api/collections/' + sibling, json={'parent_id': parent}).status_code == 422
    assert c.put('/api/collections/' + root, json={'parent_id': parent}).status_code == 400


def test_tag_rename_conflict_preserves_name(migrated_client):
    c = migrated_client
    first = c.post('/api/tags', json={'name': 'First'}).json()['id']
    c.post('/api/tags', json={'name': 'Other'})
    assert c.put('/api/tags/' + first, json={'name': 'Other'}).status_code == 409
    assert c.put('/api/tags/' + first, json={'name': None}).status_code == 422
    assert next(t for t in c.get('/api/tags').json() if t['id'] == first)['name'] == 'First'


def test_factory_reset_disables_ai(migrated_client):
    ai_policy.configure(True)
    assert migrated_client.post('/api/data/factory-reset').status_code == 200
    assert not ai_policy.enabled()


@pytest.mark.asyncio
@pytest.mark.parametrize('headers', [[], [(b'content-length', b'1')]])
async def test_actual_chunked_body_limit_prevents_handler(headers):
    from services.request_limits import RequestSizeMiddleware
    called = []
    async def app(scope, receive, send):
        called.append(True)
    chunks = iter([{'type': 'http.request', 'body': b'x' * 80, 'more_body': True},
                   {'type': 'http.request', 'body': b'x' * 80, 'more_body': False}])
    messages = []
    async def receive(): return next(chunks)
    async def send(message): messages.append(message)
    await RequestSizeMiddleware(app, lambda: 100)({'type': 'http', 'headers': headers}, receive, send)
    assert messages[0]['status'] == 413
    assert not called


def test_body_below_limit_replays_exactly():
    from services.request_limits import RequestSizeMiddleware
    app = FastAPI()
    app.add_middleware(RequestSizeMiddleware, limit=lambda: 200000)
    @app.post('/')
    async def read(request: Request):
        return {'body': (await request.body()).decode()}
    with TestClient(app) as c:
        assert c.post('/', content='z' * 130000).json()['body'] == 'z' * 130000


@pytest.fixture
def vectors():
    vector_store.reset_table(3, 'model-a')
    assert vector_store.upsert('old', [0.1, 0.2, 0.3], model_key='model-a')
    yield
    vector_store.reset_table(768)


def test_vector_update_failure_keeps_previous_embedding(vectors):
    assert not vector_store.upsert('old', [0.1], model_key='model-a')
    assert vector_store.search([0.1, 0.2, 0.3])[0][0] == 'old'


def test_vector_replacement_failure_rolls_back_table_and_identity(vectors):
    with pytest.raises(Exception):
        vector_store.replace_all([('new', [0.1, 0.2]), ('bad', [0.1])], 2, 'model-b')
    assert vector_store.matches_configuration('model-a')
    assert vector_store.search([0.1, 0.2, 0.3])[0][0] == 'old'
    vector_store.replace_all([('new', [0.1, 0.2])], 2, 'model-b')
    assert vector_store.matches_configuration('model-b')
    assert not vector_store.matches_configuration('model-a')
    assert vector_store.search([0.1, 0.2])[0][0] == 'new'


def test_equal_dimension_cannot_mix_models(vectors):
    assert not vector_store.upsert('wrong', [0.1, 0.2, 0.3], model_key='model-b')
    assert vector_store.count() == 1


def test_configuration_change_invalidates_inflight_generation(monkeypatch):
    from services import embedding_service
    monkeypatch.setattr(embedding_service, '_active_model', 'model-a')
    old = ai_policy.generation()
    embedding_service.set_active_model('model-b')
    assert ai_policy.generation() != old


def test_ready_endpoint_requires_native_session_token():
    import main
    c = TestClient(main.app, raise_server_exceptions=False)
    try:
        assert c.get('/api/ready').status_code == 401
        response = c.get('/api/ready', headers={'X-Gyrus-Token': main.API_TOKEN})
        assert response.status_code == 200
        assert response.json()['service'] == 'gyrus'
        token = c.post('/api/auth/extension-token', headers={'Origin': main.EXTENSION_ORIGINS[0]}).json()['token']
        assert c.get('/api/ready', headers={'X-Gyrus-Token': token}).status_code == 403

    finally:
        c.close()


@pytest.mark.asyncio
async def test_failed_full_reindex_retains_old_index_and_reports_error(db, monkeypatch, vectors):
    from contextlib import contextmanager
    import database
    from models.bookmark import Bookmark
    from routers import search
    from services import background, embedding_service
    db.add_all([Bookmark(id='a', title='A', url='https://a.example', scraped_content='one'),
                Bookmark(id='b', title='B', url='https://b.example', scraped_content='two')])
    db.commit()
    @contextmanager
    def session(): yield db
    monkeypatch.setattr(database, 'SessionLocal', session)
    calls = []
    async def embed(text):
        calls.append(text)
        if len(calls) == 2:
            raise RuntimeError('Ollama disconnected')
        return [0.1, 0.2]
    monkeypatch.setattr(embedding_service, 'get_embedding', embed)
    response = await search.reindex_embeddings(db)
    assert response['status'] == 'started'
    await background.drain()
    assert not search._reindex_running
    assert search._reindex_error == 'Ollama disconnected'
    assert search._reindex_completed == 1
    assert vector_store.matches_configuration('model-a')
    assert vector_store.search([0.1, 0.2, 0.3])[0][0] == 'old'


def test_snapshot_failure_leaves_no_completed_backup(tmp_path, monkeypatch):
    import sqlite3
    from services import backup_service
    source = tmp_path / 'invalid.db'
    source.write_bytes(b'This is not a SQLite database')
    destination = tmp_path / 'gyrus-20260906.db'
    with pytest.raises(sqlite3.DatabaseError):
        backup_service._snapshot(source, destination)
    assert not destination.exists()
    assert not list(tmp_path.glob('.snapshot-*'))


def test_runtime_manifest_detects_stale_inputs_and_package_metadata(tmp_path, monkeypatch):
    import runtime_manifest
    backend = tmp_path / 'backend'
    runtime = backend / 'python-runtime'
    metadata = runtime / 'lib/python3.11/site-packages/example-1.0.dist-info/METADATA'
    metadata.parent.mkdir(parents=True)
    metadata.write_text('Name: example\nVersion: 1.0\n')
    (backend / 'requirements-runtime.in').write_text('example==1.0\n')
    (backend / 'requirements-runtime.lock').write_text('example==1.0\n')
    monkeypatch.setattr(runtime_manifest, 'browsers', lambda _: {'test': '1'})
    runtime_manifest.create(backend, runtime)
    runtime_manifest.verify(backend, runtime)
    metadata.write_text('Name: example\nVersion: 2.0\n')
    with pytest.raises(ValueError, match='packages'):
        runtime_manifest.verify(backend, runtime)
    metadata.write_text('Name: example\nVersion: 1.0\n')
    (backend / 'requirements-runtime.in').write_text('example==2.0\n')
    with pytest.raises(ValueError, match='inputs_sha256'):
        runtime_manifest.verify(backend, runtime)
