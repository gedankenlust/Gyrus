import os
import pytest
from pathlib import Path
from services.brain_sync_service import brain_sync_service
from services import brain_chat_service
from database import DATA_DIR

def test_clear_cache(client):
    # Ensure directories exist and have some files
    favicons_dir = DATA_DIR / "favicons"
    og_images_dir = DATA_DIR / "og_images"
    favicons_dir.mkdir(exist_ok=True)
    og_images_dir.mkdir(exist_ok=True)
    
    test_favicon = favicons_dir / "test.png"
    test_favicon.write_text("dummy")
    
    resp = client.post("/api/data/clear-cache")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}
    assert not test_favicon.exists()

def test_clear_brain(client):
    # Ensure brain directory exists and has some files
    brain_sync_service.root_dir.mkdir(parents=True, exist_ok=True)
    test_file = brain_sync_service.root_dir / "test.md"
    test_file.write_text("dummy")
    
    resp = client.post("/api/data/clear-brain")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}
    assert not test_file.exists()

def test_clear_bookmarks(client):
    # Create a bookmark
    client.post("/api/bookmarks", json={"title": "Example", "url": "https://example.com"})
    
    # Verify it exists
    assert len(client.get("/api/bookmarks").json()) > 0
    
    resp = client.post("/api/data/clear-bookmarks")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}
    
    # Verify it's gone
    assert len(client.get("/api/bookmarks").json()) == 0

def test_factory_reset(client):
    # Setup: Create files and database entries
    favicons_dir = DATA_DIR / "favicons"
    favicons_dir.mkdir(exist_ok=True)
    test_favicon = favicons_dir / "test.png"
    test_favicon.write_text("dummy")
    
    brain_sync_service.root_dir.mkdir(parents=True, exist_ok=True)
    test_file = brain_sync_service.root_dir / "test.md"
    test_file.write_text("dummy")
    
    client.post("/api/bookmarks", json={"title": "Example", "url": "https://example.com"})
    
    resp = client.post("/api/data/factory-reset")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}
    
    assert not test_favicon.exists()
    assert not test_file.exists()
    assert len(client.get("/api/bookmarks").json()) == 0

def test_backup(client):
    resp = client.get("/api/data/backup")
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "application/json"
    assert "attachment" in resp.headers["content-disposition"]
    assert "gyrus_backup.json" in resp.headers["content-disposition"]
    body = resp.json()
    assert body["version"] == 1
    for key in ("collections", "tags", "bookmarks", "bookmark_notes", "brain_messages", "bookmark_tags"):
        assert key in body


def test_backup_restore_roundtrip(client, db):
    # Build some data: folder + nested folder + tag + bookmark with a note.
    parent = client.post("/api/collections", json={"name": "Work"}).json()
    child = client.post("/api/collections", json={"name": "Sub", "parent_id": parent["id"]}).json()
    bm = client.post("/api/bookmarks", json={
        "title": "Roundtrip", "url": "https://roundtrip.example.com",
        "collection_id": child["id"], "source": "manual"}).json()
    client.post(f"/api/bookmarks/{bm['id']}/notes", json={"content": "keep me", "source": "user"})
    brain_chat_service.add_message(db, bm["id"], "user", "remember me", model="llama3")
    brain_chat_service.add_message(db, bm["id"], "assistant", "I remembered it.", model="llama3")

    # Backup → JSON.
    backup = client.get("/api/data/backup")
    assert backup.status_code == 200
    payload = backup.json()
    assert payload["version"] == 1
    assert len(payload["collections"]) == 2
    assert len(payload["bookmarks"]) == 1

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
    assert any(n["content"] == "keep me" for n in restored["bookmark_notes"])
    chat = client.get(f"/api/brain/bookmarks/{bm['id']}/messages").json()
    assert any(m["content"] == "remember me" for m in chat)
