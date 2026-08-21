"""Soft-delete / Trash: delete moves to trash, restore, purge, auto-expiry,
and trashed bookmarks stay hidden from all normal views."""
from datetime import datetime, timezone, timedelta

from models.bookmark import Bookmark
from services import bookmark_service
from database import DATA_DIR

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


def test_delete_batch_moves_to_trash(client, db):
    from unittest.mock import patch

    a = _create(client, "https://a.com")
    b = _create(client, "https://b.com")
    c = _create(client, "https://c.com")
    d = _create(client, "https://d.com")

    # Pre-trash c so we can verify it doesn't trigger side effects again
    client.delete(f"/api/bookmarks/{c['id']}")

    with patch("services.bookmark_service.brain_sync_service.delete_bookmarks_files") as mock_delete_files, \
         patch("services.bookmark_service.brain_sync_service.rebuild_index") as mock_rebuild_index, \
         patch("services.bookmark_service._drop_vectors") as mock_drop_vectors:

        response = client.post("/api/bookmarks/delete-batch", json={"ids": [a["id"], b["id"], c["id"]]})
        assert response.status_code == 204

        # Only 'a' and 'b' should have their files deleted, since 'c' was already trashed
        mock_delete_files.assert_called_once()
        called_bms = mock_delete_files.call_args.args[1]
        assert len(called_bms) == 2
        assert {b.id for b in called_bms} == {a["id"], b["id"]}

        # Soft-delete drops vectors in one batch for newly trashed bookmarks only
        mock_drop_vectors.assert_called_once()
        dropped_ids = mock_drop_vectors.call_args.args[0]
        assert set(dropped_ids) == {a["id"], b["id"]}

        mock_rebuild_index.assert_called_once()

    # Verify db state
    assert client.get(f"/api/bookmarks/{a['id']}").status_code == 404
    assert client.get(f"/api/bookmarks/{b['id']}").status_code == 404
    assert client.get(f"/api/bookmarks/{c['id']}").status_code == 404
    assert client.get(f"/api/bookmarks/{d['id']}").status_code == 200

    trash = client.get("/api/bookmarks/trash").json()
    trashed_ids = {bm["id"] for bm in trash}
    assert a["id"] in trashed_ids
    assert b["id"] in trashed_ids
    assert c["id"] in trashed_ids
    assert d["id"] not in trashed_ids
    assert client.get("/api/bookmarks/trash/count").json() == 3


def test_delete_batch_empty_list(client):
    from unittest.mock import patch

    a = _create(client, "https://a.com")

    with patch("services.bookmark_service.brain_sync_service.delete_bookmark_file") as mock_delete_file, \
         patch("services.bookmark_service.brain_sync_service.rebuild_index") as mock_rebuild_index, \
         patch("services.bookmark_service._drop_vectors") as mock_drop_vectors:

        response = client.post("/api/bookmarks/delete-batch", json={"ids": []})
        assert response.status_code == 204

        mock_delete_file.assert_not_called()
        mock_drop_vectors.assert_called_once_with([])
        mock_rebuild_index.assert_called_once()

    assert client.get(f"/api/bookmarks/{a['id']}").status_code == 200
    assert client.get("/api/bookmarks/trash/count").json() == 0


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
    snapshot = DATA_DIR / "visual_snapshots" / bm["id"] / "snapshot.png"
    structure = DATA_DIR / "site_structure" / f"{bm['id']}-cache.json"
    snapshot.parent.mkdir(parents=True, exist_ok=True)
    structure.parent.mkdir(parents=True, exist_ok=True)
    snapshot.write_text("image")
    structure.write_text("structure")
    client.delete(f"/api/bookmarks/{bm['id']}")
    resp = client.post("/api/bookmarks/trash/purge", json={"ids": [bm["id"]]})
    assert resp.json()["purged"] == 1
    assert client.get("/api/bookmarks/trash/count").json() == 0
    assert not snapshot.exists()
    assert not structure.exists()


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
