import os
import pytest
from pathlib import Path
from services.brain_sync_service import brain_sync_service
from services import brain_chat_service
from database import DATA_DIR
from models.bookmark import Bookmark

def test_clear_cache(client):
    # Ensure directories exist and have some files
    favicons_dir = DATA_DIR / "favicons"
    og_images_dir = DATA_DIR / "og_images"
    favicons_dir.mkdir(parents=True, exist_ok=True)
    og_images_dir.mkdir(parents=True, exist_ok=True)
    
    test_favicon = favicons_dir / "test.png"
    test_favicon.write_text("dummy")
    
    # Nested directory to ensure shutil.rmtree works on directories
    nested_dir = favicons_dir / "nested"
    nested_dir.mkdir(parents=True, exist_ok=True)
    nested_file = nested_dir / "nested.png"
    nested_file.write_text("dummy_nested")

    test_og_image = og_images_dir / "test_og.png"
    test_og_image.write_text("dummy_og")

    resp = client.post("/api/data/clear-cache")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}
    assert not test_favicon.exists()
    assert not nested_dir.exists()
    assert not test_og_image.exists()

    # Ensure root cache directories themselves are not deleted
    assert favicons_dir.exists()
    assert og_images_dir.exists()

def test_clear_brain(client):
    # Gyrus files are removed, unrelated files in a selected vault are not.
    brain_sync_service.root_dir.mkdir(parents=True, exist_ok=True)
    test_file = brain_sync_service.root_dir / "test-1234abcd.md"
    test_file.write_text("dummy")
    user_file = brain_sync_service.root_dir / "my-own-note.md"
    user_file.write_text("keep")
    
    resp = client.post("/api/data/clear-brain")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}
    assert not test_file.exists()
    assert user_file.exists()

def test_clear_bookmarks(client):
    from services import vector_store

    # Create a bookmark
    bookmark = client.post(
        "/api/bookmarks", json={"title": "Example", "url": "https://example.com"}
    ).json()
    vector_store.upsert(bookmark["id"], [0.1] * 768)
    
    # Verify it exists
    assert len(client.get("/api/bookmarks").json()) > 0
    
    resp = client.post("/api/data/clear-bookmarks")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}
    
    # Verify it's gone
    assert len(client.get("/api/bookmarks").json()) == 0
    assert vector_store.count() == 0

def test_factory_reset(client):
    # Setup: Create files and database entries
    favicons_dir = DATA_DIR / "favicons"
    favicons_dir.mkdir(exist_ok=True)
    test_favicon = favicons_dir / "test.png"
    test_favicon.write_text("dummy")
    
    brain_sync_service.root_dir.mkdir(parents=True, exist_ok=True)
    test_file = brain_sync_service.root_dir / "test-1234abcd.md"
    test_file.write_text("dummy")

    generated_files = []
    for relative in (
        "visual_snapshots/bookmark-1/snapshot.png",
        "site_structure/bookmark-1.json",
        "db/backups/gyrus-previous.db",
        "python-cache/module.pyc",
    ):
        path = DATA_DIR / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("generated")
        generated_files.append(path)
    
    client.post("/api/bookmarks", json={"title": "Example", "url": "https://example.com"})
    
    resp = client.post("/api/data/factory-reset")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}
    
    assert not test_favicon.exists()
    assert not test_file.exists()
    assert all(not path.exists() for path in generated_files)
    assert len(client.get("/api/bookmarks").json()) == 0

def test_backup(client):
    resp = client.get("/api/data/backup")
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "application/json"
    assert "attachment" in resp.headers["content-disposition"]
    assert "gyrus_backup.json" in resp.headers["content-disposition"]
    body = resp.json()
    assert body["version"] == 2
    for key in ("collections", "tags", "bookmarks", "bookmark_notes", "brain_messages", "bookmark_tags"):
        assert key in body


def test_backup_restore_roundtrip(client, db):
    from datetime import datetime, timezone
    from models.tag import BookmarkTag, Tag

    # Build some data: folder + nested folder + tag + bookmark with a note.
    parent = client.post("/api/collections", json={"name": "Work"}).json()
    child = client.post("/api/collections", json={"name": "Sub", "parent_id": parent["id"]}).json()
    bm = client.post("/api/bookmarks", json={
        "title": "Roundtrip", "url": "https://roundtrip.example.com",
        "collection_id": child["id"], "source": "manual"}).json()
    client.post(f"/api/bookmarks/{bm['id']}/notes", json={"content": "keep me", "source": "user"})
    brain_chat_service.add_message(db, bm["id"], "user", "remember me", model="llama3")
    brain_chat_service.add_message(db, bm["id"], "assistant", "I remembered it.", model="llama3")
    ai_tag = Tag(name="research", color="#123456", source="ai")
    db.add(ai_tag)
    db.flush()
    db.add(BookmarkTag(bookmark_id=bm["id"], tag_id=ai_tag.id, source="ai"))
    stored = db.get(Bookmark, bm["id"])
    stored.is_read = True
    stored.scraped_content = "Durable reader text"
    stored.metadata_status = "ready"
    stored.reader_status = "ready"
    stored.index_status = "ready"
    stored.analysis_error = "Previous transient error"
    stored.analysis_attempts = 3
    stored.analysis_updated_at = datetime.now(timezone.utc)
    trashed = Bookmark(
        id="trashed-bookmark",
        title="Trashed",
        url="https://trashed.example.com",
        deleted_at=datetime.now(timezone.utc),
    )
    db.add(trashed)
    db.commit()

    # Backup → JSON.
    backup = client.get("/api/data/backup")
    assert backup.status_code == 200
    payload = backup.json()
    assert payload["version"] == 2
    assert payload["tags"][0]["source"] == "ai"
    assert len(payload["collections"]) == 2
    assert len(payload["bookmarks"]) == 2
    assert payload["bookmark_tags"] == [{
        "bookmark_id": bm["id"],
        "tag_id": ai_tag.id,
        "source": "ai",
    }]

    # Wipe everything.
    client.post("/api/data/clear-bookmarks")
    assert client.get("/api/collections").json() == []

    # Restore from the backup.
    resp = client.post("/api/data/restore", json=payload)
    assert resp.status_code == 200

    # Everything is back, with hierarchy and note intact.
    tree = client.get("/api/collections").json()
    work = next(c for c in tree if c["name"] == "Work")
    assert [c["name"] for c in work["children"]] == ["Sub"]
    restored = client.get(f"/api/bookmarks/{bm['id']}").json()
    assert restored["url"] == "https://roundtrip.example.com"
    restored_model = db.get(Bookmark, bm["id"])
    assert restored_model.is_read is True
    assert restored_model.scraped_content == "Durable reader text"
    assert restored_model.metadata_status == "ready"
    assert restored_model.reader_status == "ready"
    assert restored_model.index_status == "ready"
    assert restored_model.analysis_error == "Previous transient error"
    assert restored_model.analysis_attempts == 3
    assert restored_model.analysis_updated_at is not None
    assert db.get(Bookmark, "trashed-bookmark").deleted_at is not None
    assert any(n["content"] == "keep me" for n in restored["bookmark_notes"])
    chat = client.get(f"/api/brain/bookmarks/{bm['id']}/messages").json()
    assert any(m["content"] == "remember me" for m in chat)
    restored_link = db.query(BookmarkTag).filter(BookmarkTag.bookmark_id == bm["id"]).one()
    assert restored_link.source == "ai"
    assert db.query(Tag).filter(Tag.id == ai_tag.id).one().source == "ai"


def test_restore_accepts_version_1_backup_with_safe_defaults(client, db):
    payload = {
        "version": 1,
        "collections": [],
        "tags": [],
        "bookmarks": [{
            "id": "legacy-bookmark",
            "title": "Legacy",
            "url": "https://legacy.example.com",
            "is_dead": False,
        }],
        "bookmark_notes": [],
        "brain_messages": [],
        "bookmark_tags": [],
    }

    response = client.post("/api/data/restore", json=payload)

    assert response.status_code == 200
    restored = db.get(Bookmark, "legacy-bookmark")
    assert restored.is_read is False
    assert restored.reader_status == "pending"
    assert restored.index_status == "not_requested"
