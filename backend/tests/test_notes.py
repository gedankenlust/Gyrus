import pytest

BOOKMARK = {"title": "Note Test", "url": "https://notes.com", "source": "manual"}

def test_add_note(client):
    bm = client.post("/api/bookmarks", json=BOOKMARK).json()
    note_data = {"content": "Test note content", "source": "user"}
    resp = client.post(f"/api/bookmarks/{bm['id']}/notes", json=note_data)
    assert resp.status_code == 201
    data = resp.json()
    assert data["content"] == "Test note content"
    assert data["source"] == "user"
    assert "id" in data

    # Verify bookmark fetch includes note
    bm_resp = client.get(f"/api/bookmarks/{bm['id']}")
    assert len(bm_resp.json()["bookmark_notes"]) == 1
    assert bm_resp.json()["bookmark_notes"][0]["content"] == "Test note content"

def test_delete_note(client):
    bm = client.post("/api/bookmarks", json=BOOKMARK).json()
    note = client.post(f"/api/bookmarks/{bm['id']}/notes", json={"content": "Delete me"}).json()
    
    resp = client.delete(f"/api/bookmarks/{bm['id']}/notes/{note['id']}")
    assert resp.status_code == 204
    
    bm_resp = client.get(f"/api/bookmarks/{bm['id']}")
    assert len(bm_resp.json()["bookmark_notes"]) == 0

def test_ai_note_source(client):
    bm = client.post("/api/bookmarks", json=BOOKMARK).json()
    note = client.post(f"/api/bookmarks/{bm['id']}/notes", json={"content": "AI logic", "source": "ai"}).json()
    assert note["source"] == "ai"
