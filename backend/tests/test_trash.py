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


def test_count_trashed_service(client, db):
    # Verify that bookmark_service.count_trashed accurately returns the count of deleted items
    b1 = _create(client, "https://count1.com")
    b2 = _create(client, "https://count2.com")
    b3 = _create(client, "https://count3.com")

    assert bookmark_service.count_trashed(db) == 0

    client.delete(f"/api/bookmarks/{b1['id']}")
    assert bookmark_service.count_trashed(db) == 1

    client.delete(f"/api/bookmarks/{b2['id']}")
    assert bookmark_service.count_trashed(db) == 2

    # b3 remains not deleted
    assert bookmark_service.count_trashed(db) == 2


def test_restore_bookmarks_service(client, db):
    # Verify that bookmark_service.restore_bookmarks restores specific trashed bookmarks
    b1 = _create(client, "https://restore1.com")
    b2 = _create(client, "https://restore2.com")
    b3 = _create(client, "https://restore3.com")

    client.delete(f"/api/bookmarks/{b1['id']}")
    client.delete(f"/api/bookmarks/{b2['id']}")
    client.delete(f"/api/bookmarks/{b3['id']}")

    assert bookmark_service.count_trashed(db) == 3

    # Restore a single bookmark
    restored_count = bookmark_service.restore_bookmarks(db, [b2['id']])
    assert restored_count == 1

    assert bookmark_service.count_trashed(db) == 2

    # Verify that it is no longer marked as deleted
    restored_bm = db.query(Bookmark).filter(Bookmark.id == b2['id']).first()
    assert restored_bm.deleted_at is None

    # Restore multiple remaining bookmarks
    restored_count_multi = bookmark_service.restore_bookmarks(db, [b1['id'], b3['id']])
    assert restored_count_multi == 2
    assert bookmark_service.count_trashed(db) == 0
