"""Regressions from the full application review, including migrated SQLite/FTS."""
import asyncio
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import AsyncMock

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker
from alembic import command
from alembic.config import Config

from database import get_db, DATA_DIR
from models.bookmark import Bookmark
from models.collection import Collection
from services import ai_policy, background, vector_store
from services.brain_sync_service import BrainSyncService
from services.search_service import search_bookmarks
import main


@pytest.fixture
def migrated(tmp_path):
    # All migrations, triggers and expression indexes used in production.
    engine = create_engine(f"sqlite:///{tmp_path / 'migrated.db'}", connect_args={"check_same_thread": False})
    cfg = Config(str(Path(__file__).parents[1] / "alembic.ini"))
    cfg.set_main_option("script_location", str(Path(__file__).parents[1] / "alembic"))
    with engine.begin() as connection:
        cfg.attributes["connection"] = connection
        command.upgrade(cfg, "head")
    session = sessionmaker(bind=engine)()
    try:
        yield session
    finally:
        session.close()
        engine.dispose()


@pytest.fixture
def migrated_client(migrated, monkeypatch):
    def no_background(coro):
        coro.close()
    monkeypatch.setattr(background, "schedule", no_background)
    main.app.dependency_overrides[get_db] = lambda: migrated
    client = TestClient(main.app, headers={"X-Gyrus-Token": main.API_TOKEN})
    try:
        yield client
    finally:
        main.app.dependency_overrides.clear()
        client.close()


def test_migration_and_model_indexes_match(migrated, engine):
    actual = migrated.execute(text("SELECT sql FROM sqlite_master WHERE name='idx_collection_name_parent_unique'")).scalar()
    with engine.connect() as connection:
        model = connection.execute(text("SELECT sql FROM sqlite_master WHERE name='idx_collection_name_parent_unique'")).scalar()
    assert "ifnull(parent_id" in actual.lower()
    assert "ifnull(parent_id" in model.lower()
    assert "ifnull('parent_id'" not in model.lower()


def test_restore_duplicate_child_names_and_reversed_order(migrated_client):
    c = migrated_client
    for name in ("Work", "Private"):
        parent = c.post('/api/collections', json={"name": name}).json()
        assert c.post('/api/collections', json={"name": "Notes", "parent_id": parent['id']}).status_code == 201
    payload = c.get('/api/data/backup').json()
    payload['collections'].reverse()
    assert c.post('/api/data/restore', json=payload).status_code == 200
    tree = c.get('/api/collections').json()
    assert len(tree) == 2
    assert all([child['name'] for child in row['children']] == ['Notes'] for row in tree)


@pytest.mark.parametrize('bad', [
    {'collections': [{'id': 'a', 'name': 'A', 'parent_id': 'b'}, {'id': 'b', 'name': 'B', 'parent_id': 'a'}]},
    {'collections': [{'id': 'a', 'name': 'A', 'parent_id': 'missing'}]},
    {'collections': [{'id': 'a', 'name': 'A'}, {'id': 'b', 'name': 'A'}]},
    {'bookmarks': [{'id': '../outside', 'url': 'https://example.com'}]},
    {'bookmarks': [{'id': 'a', 'url': 'https://example.com', 'title': None}]},
    {'bookmarks': [{'id': 'a', 'url': 'file:///etc/passwd'}]},
    {'bookmarks': [{'id': 'a', 'url': 'https://example.com', 'is_read': 'false'}]},
    {'bookmark_notes': [{'id': 'n', 'bookmark_id': 'missing', 'content': 'text'}]},
    {'bookmark_tags': [{'bookmark_id': [], 'tag_id': {}}]},
    {'tags': [{'id': 't'}]},
])
def test_invalid_restore_preserves_library(migrated_client, bad):
    c = migrated_client
    saved = c.post('/api/bookmarks', json={'title': 'Keep', 'url': 'https://keep.example'}).json()
    assert c.post('/api/data/restore', json=bad).status_code == 422
    assert c.get('/api/bookmarks/' + saved['id']).status_code == 200


def test_restore_invalidates_vectors_and_capture_cache(migrated_client, migrated):
    c = migrated_client
    saved = c.post('/api/bookmarks', json={'title': 'Keep', 'url': 'https://keep.example'}).json()
    bid = saved['id']
    migrated.get(Bookmark, bid).index_status = 'ready'
    migrated.commit()
    vector_store.upsert(bid, [0.1] * 768)
    cache = DATA_DIR / 'visual_snapshots' / bid / 'snapshot.json'
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text('{}')
    payload = c.get('/api/data/backup').json()
    assert c.post('/api/data/restore', json=payload).status_code == 200
    migrated.expire_all()
    assert migrated.get(Bookmark, bid).index_status == 'not_requested'
    assert vector_store.count() == 0
    assert not cache.exists()


def test_fts_pages_exclude_trash_before_pagination(migrated, migrated_client):
    for index in range(12):
        migrated.add(Bookmark(title='findable', url=f'https://example.com/{index}',
                              deleted_at=datetime.now(timezone.utc) if index % 2 == 0 else None))
    migrated.commit()
    assert migrated.execute(text("SELECT count(*) FROM bookmarks_fts WHERE bookmarks_fts MATCH 'findable'")).scalar() == 12
    pages = [search_bookmarks(migrated, 'findable', limit=3, offset=n) for n in (0, 3, 6)]
    assert [len(page) for page in pages] == [3, 3, 0]
    assert len({bm.id for page in pages for bm in page}) == 6
    # Select-all must use the same FTS/notes/chat/tag semantics as visible search.
    target = pages[0][0]
    migrated_client.post(f'/api/bookmarks/{target.id}/notes', json={'content': 'unique-note-needle'})
    assert migrated_client.get('/api/bookmarks/ids', params={'q': 'unique-note-needle'}).json() == [target.id]


def test_export_scope_matches_across_html_and_pages(migrated_client):
    c = migrated_client
    root = c.post('/api/collections', json={'name': 'Export this'}).json()['id']
    child = c.post('/api/collections', json={'name': 'Sub', 'parent_id': root}).json()['id']
    for name, cid in [('included-root', root), ('included-child', child), ('excluded-outside', None), ('excluded-trash', root)]:
        saved = c.post('/api/bookmarks', json={'title': name, 'url': f'https://{name}.example', 'collection_id': cid}).json()
        if name == 'excluded-trash':
            c.delete('/api/bookmarks/' + saved['id'])
    html = c.get('/api/export/html', params={'collection_id': root})
    assert html.status_code == 200
    assert 'included-root' in html.text and 'included-child' in html.text
    assert 'excluded-' not in html.text
    pages = [c.get('/api/export/bookmarks', params={'collection_id': root, 'limit': 1, 'offset': n}).json() for n in range(3)]
    assert [len(page) for page in pages] == [1, 1, 0]
    assert {row['title'] for page in pages for row in page} == {'included-root', 'included-child'}
    assert c.get('/api/export/html', params={'collection_id': 'missing'}).status_code == 404


def test_url_change_removes_previous_page_analysis(migrated_client, migrated):
    c = migrated_client
    saved = c.post('/api/bookmarks', json={'title': 'Old page', 'url': 'https://old.example'}).json()
    bid = saved['id']
    bm = migrated.get(Bookmark, bid)
    bm.scraped_content = 'Old article body'
    bm.index_status = bm.reader_status = bm.metadata_status = 'ready'
    bm.favicon_path = 'old.png'
    migrated.commit()
    vector_store.upsert(bid, [0.1] * 768)
    result = c.put('/api/bookmarks/' + bid, json={'url': 'https://new.example'})
    assert result.status_code == 200
    migrated.expire_all()
    bm = migrated.get(Bookmark, bid)
    assert bm.scraped_content is None and bm.favicon_path is None
    assert bm.reader_status == bm.metadata_status == 'pending'
    assert bm.index_status == 'not_requested'
    assert not search_bookmarks(migrated, 'Old article body')
    assert vector_store.count() == 0


def test_scoped_extension_token_stays_scoped_without_origin():
    c = TestClient(main.app)  # No lifespan: no startup work.
    token = c.post('/api/auth/extension-token', headers={'Origin': main.EXTENSION_ORIGINS[0]}).json()['token']
    assert token != main.API_TOKEN
    headers = {'X-Gyrus-Token': token}
    assert c.get('/api/data/backup', headers=headers).status_code == 403
    assert c.post('/api/data/factory-reset', headers=headers).status_code == 403
    assert c.post('/api/bookmarks', headers=headers, json={}).status_code == 422
    c.close()


def test_brain_preserves_foreign_files_and_index(db, tmp_path):
    brain = BrainSyncService(str(tmp_path))
    assert brain.is_enabled is False
    brain.update_config(str(tmp_path), True)
    bm = Bookmark(title='A note', url='https://example.com')
    db.add(bm)
    db.commit()
    foreign = tmp_path / '_Unsorted' / brain.bookmark_filename(bm.id, bm.title)
    foreign.parent.mkdir()
    foreign.write_text('My own note with a coincidentally similar name')
    own_index = tmp_path / '_Index.md'
    own_index.write_text('My own index')
    other = tmp_path / 'notes-1234abcd.md'
    other.write_text('My own unrelated note')
    brain.sync_bookmark(db, bm)
    brain.rebuild_index(db, force=True)
    generated = brain._get_bookmark_file_path(db, bm)
    assert generated != foreign and generated.exists()
    assert generated.name in brain.index_path().read_text().replace('%20', ' ')
    brain.clear_all_files()
    assert not generated.exists()
    assert foreign.read_text().startswith('My own')
    assert own_index.read_text() == 'My own index'
    assert other.read_text() == 'My own unrelated note'


def test_brain_updates_metadata_preserving_appended_text_and_external_edits(db, tmp_path):
    brain = BrainSyncService(str(tmp_path))
    brain.update_config(str(tmp_path), True)
    bm = Bookmark(title='Original', url='https://example.com', description='Before')
    db.add(bm)
    db.commit()
    brain.sync_bookmark(db, bm)
    original = brain._get_bookmark_file_path(db, bm)
    original.write_text(original.read_text() + '\nMy appended text\n')
    bm.title = 'Renamed'
    bm.description = 'After'
    db.commit()
    brain.sync_bookmark(db, bm, old_path=original)
    renamed = brain._get_bookmark_file_path(db, bm)
    assert not original.exists()
    assert 'After' in renamed.read_text() and 'My appended text' in renamed.read_text()
    edited = renamed.read_text().replace('After', 'External edit')
    renamed.write_text(edited)
    bm.description = 'Later'
    db.commit()
    brain.sync_bookmark(db, bm)
    assert renamed.read_text() == edited


def test_brain_symlink_does_not_escape_root(db, tmp_path):
    root = tmp_path / 'vault'
    outside = tmp_path / 'outside'
    outside.mkdir()
    brain = BrainSyncService(str(root))
    brain.update_config(str(root), True)
    (root / '_Unsorted').symlink_to(outside, target_is_directory=True)
    bm = Bookmark(title='Escape', url='https://example.com')
    db.add(bm)
    db.commit()
    with pytest.raises(ValueError):
        brain.sync_bookmark(db, bm)
    assert list(outside.iterdir()) == []


def test_ai_disabled_gates_routes_and_status_without_network(client, monkeypatch):
    ai_policy.configure(False)
    forbidden = AsyncMock(side_effect=AssertionError('AI request while disabled'))
    monkeypatch.setattr('httpx.AsyncClient.get', forbidden)
    for path in ('/api/search/semantic?q=test', '/api/search/status'):
        result = client.get(path)
        assert result.status_code in {200, 503}
    for path in ('/api/brain/chat', '/api/search/reindex', '/api/bookmarks/a/auto-tag', '/api/bookmarks/a/reader/translate'):
        assert client.post(path, json={}).status_code == 503
    forbidden.assert_not_called()


@pytest.mark.asyncio
async def test_disable_during_embedding_discards_result(monkeypatch):
    from services.embedding_service import get_embedding, EmbeddingUnavailableError
    import httpx
    async def post(*args, **kwargs):
        ai_policy.configure(False)
        return httpx.Response(200, json={'embedding': [0.1]}, request=httpx.Request('POST', 'http://localhost/api/embeddings'))
    ai_policy.configure(True)
    monkeypatch.setattr(httpx.AsyncClient, 'post', post)
    with pytest.raises(EmbeddingUnavailableError):
        await get_embedding('content')


def test_semantic_status_uses_active_model_and_url(client, monkeypatch):
    import httpx
    from services import embedding_service
    monkeypatch.setattr(embedding_service, '_active_model', 'custom:small')
    monkeypatch.setattr(embedding_service, '_active_base_url', 'http://127.0.0.1:12345')
    async def get(self, url):
        assert url == 'http://127.0.0.1:12345/api/tags'
        return httpx.Response(200, json={'models': [{'name': 'custom:small'}]}, request=httpx.Request('GET', url))
    monkeypatch.setattr(httpx.AsyncClient, 'get', get)
    monkeypatch.setattr(vector_store, 'count', lambda: 1)
    monkeypatch.setattr(vector_store, 'matches_configuration', lambda key: key == embedding_service.configuration_key())
    assert client.get('/api/search/status').json()['available'] is True


@pytest.mark.asyncio
async def test_busy_background_refuses_restore_before_wipe(migrated_client):
    c = migrated_client
    saved = c.post('/api/bookmarks', json={'title': 'Keep', 'url': 'https://keep.example'}).json()
    work = background.track(asyncio.create_task(asyncio.sleep(10)))
    try:
        result = c.post('/api/data/restore', json={'version': 1, 'collections': [], 'tags': [], 'bookmarks': []})
        assert result.status_code == 409
        assert 'Background work' in result.json()['detail']
        assert c.get('/api/bookmarks/' + saved['id']).status_code == 200
    finally:
        work.cancel()
        await asyncio.gather(work, return_exceptions=True)
    assert c.post('/api/data/restore', json={'version': 1, 'collections': [], 'tags': [], 'bookmarks': []}).status_code == 200


@pytest.mark.asyncio
async def test_maintenance_holds_reservation_through_response():
    import httpx
    from fastapi import FastAPI
    from services.maintenance import MaintenanceMiddleware, reserve
    app = FastAPI()
    app.add_middleware(MaintenanceMiddleware)
    reserved = asyncio.Event()
    finish = asyncio.Event()

    @app.post('/api/replace')
    async def replace():
        reserve()
        reserved.set()
        await finish.wait()
        return {'status': 'ok'}

    @app.get('/api/read')
    async def read():
        return {'status': 'ok'}

    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
        task = asyncio.create_task(client.post('/api/replace'))
        await reserved.wait()
        try:
            assert (await client.get('/api/read')).status_code == 409
        finally:
            finish.set()
        assert (await task).status_code == 200
        assert (await client.get('/api/read')).status_code == 200


def test_restore_requeues_index_only_with_ai_enabled(migrated_client, monkeypatch):
    from services import bookmark_enrichment_service
    queued = []
    monkeypatch.setattr(bookmark_enrichment_service, 'schedule_index', lambda ident, content: queued.append((ident, content)))
    payload = {'version': 1, 'collections': [], 'tags': [], 'bookmarks': [{'id': 'restored', 'title': 'Read', 'url': 'https://example.com', 'scraped_content': 'Durable article'}]}
    ai_policy.configure(False)
    assert migrated_client.post('/api/data/restore', json=payload).status_code == 200
    assert not queued
    ai_policy.configure(True)
    assert migrated_client.post('/api/data/restore', json=payload).status_code == 200
    assert queued == [('restored', 'Durable article')]


def test_note_changes_refresh_owned_brain_mirror(client, db, tmp_path):
    from services.brain_sync_service import brain_sync_service
    brain_sync_service.update_config(str(tmp_path), True)
    saved = client.post('/api/bookmarks', json={'title': 'Note', 'url': 'https://example.com'}).json()
    note = client.post('/api/bookmarks/' + saved['id'] + '/notes', json={'content': 'Remember this'}).json()
    path = brain_sync_service._get_bookmark_file_path(db, db.get(Bookmark, saved['id']))
    assert 'Remember this' in path.read_text()
    assert client.delete('/api/bookmarks/' + saved['id'] + '/notes/' + note['id']).status_code == 204
    assert 'Remember this' not in path.read_text()


def test_url_update_duplicate_and_null_are_rejected_without_changing_content(migrated_client, migrated):
    c = migrated_client
    first = c.post('/api/bookmarks', json={'title': 'First', 'url': 'https://first.example'}).json()
    c.post('/api/bookmarks', json={'title': 'Other', 'url': 'https://other.example'})
    assert c.put('/api/bookmarks/' + first['id'], json={'url': 'https://other.example/?utm_source=test'}).status_code == 409
    for field in ('title', 'url', 'is_read', 'is_dead'):
        assert c.put('/api/bookmarks/' + first['id'], json={field: None}).status_code == 422
    assert migrated.get(Bookmark, first['id']).url == 'https://first.example'


@pytest.mark.asyncio
async def test_chat_does_not_reuse_mirror_scrape_from_another_url(db, tmp_path, monkeypatch):
    from routers.brain import _prepare_context, _persist_scraped_content
    from services.brain_sync_service import brain_sync_service
    brain_sync_service.update_config(str(tmp_path), True)
    bm = Bookmark(title='Old', url='https://old.example')
    db.add(bm)
    db.commit()
    brain_sync_service.sync_bookmark(db, bm)
    path = brain_sync_service._get_bookmark_file_path(db, bm)
    _persist_scraped_content(path, 'Old content ' * 40, bm.url)
    bm.url = 'https://new.example'
    db.commit()
    scrape = AsyncMock(return_value={'content': 'New page content'})
    monkeypatch.setattr('services.scraper_service.scraper_service.extract_content', scrape)
    monkeypatch.setattr(background, 'schedule', lambda coro: coro.close())
    result = await _prepare_context(db, bm)
    assert result == 'New page content'
    scrape.assert_awaited_once_with('https://new.example')


def test_brain_index_refreshes_after_rapid_rename(db, tmp_path):
    from services import bookmark_service
    from schemas.bookmark import BookmarkCreate, BookmarkUpdate
    from services.brain_sync_service import brain_sync_service
    brain_sync_service.update_config(str(tmp_path), True)
    bm = bookmark_service.create_bookmark(db, BookmarkCreate(title='First', url='https://example.com'))
    old_name = brain_sync_service._get_bookmark_file_path(db, bm).name
    bookmark_service.update_bookmark(db, bm, BookmarkUpdate(title='Second'))
    new_name = brain_sync_service._get_bookmark_file_path(db, bm).name
    index = brain_sync_service.index_path().read_text()
    assert new_name in index
    assert old_name not in index


def test_import_creates_actual_brain_files_for_index_links(db, tmp_path):
    from services.import_service import parse_netscape_html
    from services.brain_sync_service import brain_sync_service
    brain_sync_service.update_config(str(tmp_path), True)
    stats = parse_netscape_html('<DL><p><DT><A HREF="https://example.com">Imported</A></DL>', db)
    assert stats['imported'] == 1
    bm = db.query(Bookmark).one()
    path = brain_sync_service._get_bookmark_file_path(db, bm)
    assert path.exists()
    assert path.name in brain_sync_service.index_path().read_text()


@pytest.mark.asyncio
async def test_disabling_ai_prevents_compatibility_retry(monkeypatch):
    import httpx
    from services import llm_service
    class Client:
        is_closed = False
        calls = 0
        async def post(self, url, **kwargs):
            self.calls += 1
            ai_policy.configure(False)
            return httpx.Response(400, request=httpx.Request('POST', url))
    fake = Client()
    monkeypatch.setattr(llm_service, '_shared_client', fake)
    with pytest.raises(llm_service.LLMUnavailableError):
        await llm_service.LLMService.ask_llm('Question', 'Context', {'provider': 'ollama', 'model': 'test'}, think=False)
    assert fake.calls == 1
