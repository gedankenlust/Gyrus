"""Semantic search: embedding indexing, vector store, and the search endpoint."""
import pytest
from unittest.mock import AsyncMock, patch

from services import vector_store
from services.bookmark_service import index_bookmark_embedding


BOOKMARK = {"title": "SQLite FTS", "url": "https://sqlite.org/fts5.html", "source": "manual"}
FAKE_VEC = [0.1] * 768  # placeholder vector — avoids real Ollama calls in tests


# ---------------------------------------------------------------------------
# vector_store unit tests (no DB, no Ollama)
# ---------------------------------------------------------------------------

def test_vector_store_upsert_and_count():
    n_before = vector_store.count()
    vector_store.upsert("test-vs-1", FAKE_VEC)
    assert vector_store.count() == n_before + 1
    vector_store.delete("test-vs-1")
    assert vector_store.count() == n_before


def test_vector_store_delete_is_idempotent():
    vector_store.delete("nonexistent-id")  # must not raise


def test_vector_store_search_returns_nearest():
    vector_store.upsert("vs-a", FAKE_VEC)
    vector_store.upsert("vs-b", [0.9] * 768)
    results = vector_store.search(FAKE_VEC, k=5)
    ids = [r[0] for r in results]
    assert "vs-a" in ids
    # clean up
    vector_store.delete("vs-a")
    vector_store.delete("vs-b")


def test_reset_table_supports_switching_dimensions():
    """Switching embedding models changes the vector size (nomic 768 ↔ bge-m3
    1024). reset_table must rebuild the table so the new size inserts cleanly."""
    try:
        # A 1024-dim model like bge-m3.
        vector_store.reset_table(1024)
        vector_store.upsert("dim-1024", [0.2] * 1024)
        assert vector_store.count() == 1
        # Back to a 768-dim model like nomic — table is rebuilt, old vectors gone.
        vector_store.reset_table(768)
        assert vector_store.count() == 0
        vector_store.upsert("dim-768", [0.1] * 768)
        assert vector_store.count() == 1
    finally:
        # Leave a clean 768-dim table for the other tests.
        vector_store.reset_table(768)


def test_reset_table_rejects_invalid_dimension():
    with pytest.raises(ValueError):
        vector_store.reset_table(0)


# ---------------------------------------------------------------------------
# index_bookmark_embedding (mocks Ollama)
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_index_embedding_stores_vector():
    n_before = vector_store.count()
    with patch(
        "services.embedding_service.get_embedding",
        new=AsyncMock(return_value=FAKE_VEC),
    ):
        await index_bookmark_embedding("bm-embed-test", "some page content")
    assert vector_store.count() == n_before + 1
    vector_store.delete("bm-embed-test")


@pytest.mark.asyncio
async def test_index_embedding_skips_on_unavailable():
    """Ollama down → no error, no vector stored."""
    from services.embedding_service import EmbeddingUnavailableError
    n_before = vector_store.count()
    with patch(
        "services.embedding_service.get_embedding",
        new=AsyncMock(side_effect=EmbeddingUnavailableError("Ollama down")),
    ):
        await index_bookmark_embedding("bm-embed-fail", "content")
    assert vector_store.count() == n_before


# ---------------------------------------------------------------------------
# /api/search/semantic endpoint
# ---------------------------------------------------------------------------

def test_semantic_search_empty_query_returns_empty(client):
    resp = client.get("/api/search/semantic?q=")
    assert resp.status_code == 200
    assert resp.json() == []


def test_semantic_search_unavailable_returns_empty(client):
    """When Ollama is unreachable the endpoint returns [] gracefully."""
    from services.embedding_service import EmbeddingUnavailableError
    with patch(
        "services.embedding_service.get_embedding",
        new=AsyncMock(side_effect=EmbeddingUnavailableError("Ollama down")),
    ):
        resp = client.get("/api/search/semantic?q=test")
    assert resp.status_code == 200
    assert resp.json() == []


def test_semantic_search_returns_indexed_bookmark(client, db):
    bm = client.post("/api/bookmarks", json=BOOKMARK).json()
    # Manually insert a vector for this bookmark.
    vector_store.upsert(bm["id"], FAKE_VEC)
    with patch(
        "services.embedding_service.get_embedding",
        new=AsyncMock(return_value=FAKE_VEC),
    ):
        resp = client.get("/api/search/semantic?q=fts5+full+text+search")
    assert resp.status_code == 200
    ids = [b["id"] for b in resp.json()]
    assert bm["id"] in ids
    vector_store.delete(bm["id"])


def test_semantic_status_endpoint(client):
    resp = client.get("/api/search/status")
    assert resp.status_code == 200
    data = resp.json()
    assert "available" in data
    assert "indexed" in data
    assert "message" in data


# ---------------------------------------------------------------------------
# Vector lifecycle: trash / restore / purge must keep the index in sync
# ---------------------------------------------------------------------------

def test_single_trash_removes_vector(client):
    bm = client.post("/api/bookmarks", json=BOOKMARK).json()
    vector_store.upsert(bm["id"], FAKE_VEC)
    n_before = vector_store.count()
    client.delete(f"/api/bookmarks/{bm['id']}")
    assert vector_store.count() == n_before - 1


def test_bulk_trash_removes_vectors(client):
    a = client.post("/api/bookmarks", json={**BOOKMARK, "url": "https://vec-a.com"}).json()
    b = client.post("/api/bookmarks", json={**BOOKMARK, "url": "https://vec-b.com"}).json()
    vector_store.upsert(a["id"], FAKE_VEC)
    vector_store.upsert(b["id"], FAKE_VEC)
    n_before = vector_store.count()
    resp = client.post("/api/bookmarks/delete-batch", json={"ids": [a["id"], b["id"]]})
    assert resp.status_code == 204
    assert vector_store.count() == n_before - 2


def test_purge_removes_orphan_vectors(client, db):
    """A vector that survived trashing must not outlive the hard delete."""
    bm = client.post("/api/bookmarks", json={**BOOKMARK, "url": "https://vec-purge.com"}).json()
    client.delete(f"/api/bookmarks/{bm['id']}")
    # Simulate a stale index entry left behind (e.g. created pre-fix).
    vector_store.upsert(bm["id"], FAKE_VEC)
    n_before = vector_store.count()
    resp = client.post("/api/bookmarks/trash/purge", json={"ids": [bm["id"]]})
    assert resp.json()["purged"] == 1
    assert vector_store.count() == n_before - 1


def test_purge_expired_removes_vectors(db):
    from datetime import datetime, timezone, timedelta
    from models.bookmark import Bookmark
    from services import bookmark_service

    bm = Bookmark(title="Old", url="https://vec-expired.com", source="manual")
    bm.deleted_at = datetime.now(timezone.utc) - timedelta(days=99)
    db.add(bm)
    db.commit()
    vector_store.upsert(bm.id, FAKE_VEC)
    n_before = vector_store.count()
    assert bookmark_service.purge_expired(db, days=30) == 1
    assert vector_store.count() == n_before - 1


@pytest.mark.asyncio
async def test_restore_reindexes_embedding(db):
    """Restoring from Trash rebuilds the vector that trashing removed."""
    from models.bookmark import Bookmark
    from services import bookmark_service, background

    bm = Bookmark(title="Restored", url="https://vec-restore.com", source="manual")
    bm.scraped_content = "some scraped page content"
    db.add(bm)
    db.commit()

    bookmark_service.delete_bookmark(db, bm)
    n_trashed = vector_store.count()

    with patch(
        "services.embedding_service.get_embedding",
        new=AsyncMock(return_value=FAKE_VEC),
    ):
        assert bookmark_service.restore_bookmarks(db, [bm.id]) == 1
        await background.drain()

    assert vector_store.count() == n_trashed + 1
    vector_store.delete(bm.id)
