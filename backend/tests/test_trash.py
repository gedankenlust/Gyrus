"""Soft-delete / Trash: delete moves to trash, restore, purge, auto-expiry,
and trashed bookmarks stay hidden from all normal views."""
from datetime import datetime, timezone, timedelta

from models.bookmark import Bookmark
from services import bookmark_service

BOOKMARK = {"title": "Example", "url": "https://example.com", "source": "manual"}


def _create(client, url="https://example.com"):
    return client.post("/api/bookmarks", json={**BOOKMARK, "url": url}).json()


def test_delete_moves_to_trash_not_gone(client):
    bm = _create(client)
    assert client.delete(f"/api/bookmarks/{bm['id']}").status_code == 204
    # Hidden from normal views...
    assert client.get(f"/api/bookmarks/{bm['id']}").status_code == 404
    assert all(b["id"] != bm["id"] for b in client.get("/api/bookmarks").json())
    assert client.get("/api/bookmarks/count").json() == 0
    # ...but recoverable in the Trash.
    trash = client.get("/api/bookmarks/trash").json()
    assert any(b["id"] == bm["id"] for b in trash)
    assert client.get("/api/bookmarks/trash/count").json() == 1


def test_trashed_bookmark_details_remain_available(client):
    bm = client.post(
        "/api/bookmarks",
        json={**BOOKMARK, "url": "https://trashed-details.example", "notes": "keep me"},
    ).json()
    client.delete(f"/api/bookmarks/{bm['id']}")

    response = client.get(f"/api/bookmarks/trash/{bm['id']}")
    assert response.status_code == 200
    assert response.json()["notes"] == "keep me"


def test_restore_brings_it_back(client):
    bm = _create(client)
    client.delete(f"/api/bookmarks/{bm['id']}")
    resp = client.post("/api/bookmarks/trash/restore", json={"ids": [bm["id"]]})
    assert resp.status_code == 200
    assert resp.json()["restored"] == 1
    assert client.get(f"/api/bookmarks/{bm['id']}").status_code == 200
    assert client.get("/api/bookmarks/trash/count").json() == 0
    assert client.get("/api/bookmarks/count").json() == 1


def test_purge_specific_is_permanent(client):
    bm = _create(client)
    client.delete(f"/api/bookmarks/{bm['id']}")
    resp = client.post("/api/bookmarks/trash/purge", json={"ids": [bm["id"]]})
    assert resp.json()["purged"] == 1
    assert client.get("/api/bookmarks/trash/count").json() == 0


def test_empty_trash_purges_all(client):
    a = _create(client, "https://a.com")
    b = _create(client, "https://b.com")
    client.delete(f"/api/bookmarks/{a['id']}")
    client.delete(f"/api/bookmarks/{b['id']}")
    resp = client.post("/api/bookmarks/trash/purge", json={})  # no ids = empty all
    assert resp.json()["purged"] == 2
    assert client.get("/api/bookmarks/trash/count").json() == 0


def test_trashed_excluded_from_search(client):
    bm = _create(client, "https://findme.com")
    assert len(client.get("/api/search?q=findme").json()) == 1
    client.delete(f"/api/bookmarks/{bm['id']}")
    assert client.get("/api/search?q=findme").json() == []


def test_purge_expired_only_removes_old(client, db):
    fresh = _create(client, "https://fresh.com")
    old = _create(client, "https://old.com")
    client.delete(f"/api/bookmarks/{fresh['id']}")
    client.delete(f"/api/bookmarks/{old['id']}")
    # Backdate the "old" one beyond the retention window.
    db.query(Bookmark).filter(Bookmark.id == old["id"]).update(
        {Bookmark.deleted_at: datetime.now(timezone.utc) - timedelta(days=40)}
    )
    db.commit()

    purged = bookmark_service.purge_expired(db, days=30)
    assert purged == 1
    assert client.get("/api/bookmarks/trash/count").json() == 1  # only the fresh one remains

def test_purge_bookmarks_drops_vectors_and_deletes(client, db):
    from unittest.mock import patch

    # Create two bookmarks
    bm1 = _create(client, "https://to-trash.com")
    bm2 = _create(client, "https://to-keep.com")
    bm3 = _create(client, "https://to-trash-2.com")

    # Trash bm1 and bm3
    client.delete(f"/api/bookmarks/{bm1['id']}")
    client.delete(f"/api/bookmarks/{bm3['id']}")

    with patch("services.bookmark_service._drop_vectors") as mock_drop:
        # Purge specifically bm1
        purged = bookmark_service.purge_bookmarks(db, ids=[bm1["id"]])
        assert purged == 1
        mock_drop.assert_called_once_with([bm1["id"]])

        # Verify bm1 is completely gone
        assert db.query(Bookmark).filter(Bookmark.id == bm1["id"]).count() == 0

        # Verify bm3 is still in trash
        assert db.query(Bookmark).filter(Bookmark.id == bm3["id"]).count() == 1

        # Verify bm2 is unaffected
        assert db.query(Bookmark).filter(Bookmark.id == bm2["id"]).count() == 1

    with patch("services.bookmark_service._drop_vectors") as mock_drop_all:
        # Purge all remaining trashed bookmarks (just bm3)
        purged_all = bookmark_service.purge_bookmarks(db, ids=None)
        assert purged_all == 1
        mock_drop_all.assert_called_once_with([bm3["id"]])

        # Verify bm3 is gone
        assert db.query(Bookmark).filter(Bookmark.id == bm3["id"]).count() == 0

        # Verify bm2 is still unaffected (it was not in trash)
        assert db.query(Bookmark).filter(Bookmark.id == bm2["id"]).count() == 1
