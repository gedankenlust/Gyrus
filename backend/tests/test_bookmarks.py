import pytest


BOOKMARK = {"title": "Example", "url": "https://example.com", "source": "manual"}


def test_create_bookmark(client):
    resp = client.post("/api/bookmarks", json=BOOKMARK)
    assert resp.status_code == 201
    data = resp.json()
    assert data["url"] == BOOKMARK["url"]
    assert data["title"] == BOOKMARK["title"]
    assert "id" in data


def test_read_bookmark(client):
    created = client.post("/api/bookmarks", json=BOOKMARK).json()
    resp = client.get(f"/api/bookmarks/{created['id']}")
    assert resp.status_code == 200
    assert resp.json()["id"] == created["id"]


def test_update_bookmark(client):
    created = client.post("/api/bookmarks", json=BOOKMARK).json()
    resp = client.put(
        f"/api/bookmarks/{created['id']}",
        json={"title": "Updated"},
    )
    assert resp.status_code == 200
    assert resp.json()["title"] == "Updated"


def test_delete_bookmark(client):
    created = client.post("/api/bookmarks", json=BOOKMARK).json()
    resp = client.delete(f"/api/bookmarks/{created['id']}")
    assert resp.status_code == 204
    assert client.get(f"/api/bookmarks/{created['id']}").status_code == 404


def test_duplicate_url_returns_409(client):
    client.post("/api/bookmarks", json=BOOKMARK)
    resp = client.post("/api/bookmarks", json=BOOKMARK)
    assert resp.status_code == 409


def test_list_bookmarks(client):
    client.post("/api/bookmarks", json=BOOKMARK)
    resp = client.get("/api/bookmarks")
    assert resp.status_code == 200
    assert len(resp.json()) >= 1


def test_bookmark_ids(client):
    created = client.post("/api/bookmarks", json=BOOKMARK).json()
    resp = client.get("/api/bookmarks/ids")
    assert resp.status_code == 200
    assert created["id"] in resp.json()


def test_sort_by_tag(client):
    apple = client.post("/api/tags", json={"name": "apple"}).json()
    zebra = client.post("/api/tags", json={"name": "zebra"}).json()
    # A: untagged, B: zebra, C: apple
    client.post("/api/bookmarks", json={"title": "A", "url": "https://a.example.com", "source": "manual"})
    client.post("/api/bookmarks", json={"title": "B", "url": "https://b.example.com", "source": "manual", "tag_ids": [zebra["id"]]})
    client.post("/api/bookmarks", json={"title": "C", "url": "https://c.example.com", "source": "manual", "tag_ids": [apple["id"]]})

    titles = [b["title"] for b in client.get("/api/bookmarks", params={"sort_by": "tag", "order": "asc"}).json()]
    # apple < zebra, untagged last.
    assert titles == ["C", "B", "A"]
    titles_desc = [b["title"] for b in client.get("/api/bookmarks", params={"sort_by": "tag", "order": "desc"}).json()]
    assert titles_desc == ["B", "C", "A"]  # zebra, apple, then untagged last

def test_auto_tag_bookmark(client, db):
    # Mock LLM service to avoid real calls
    from unittest.mock import patch
    with patch("services.llm_service.LLMService.ask_llm") as mock_ask:
        mock_ask.return_value = "ai, future, tech"
        
        # Create a bookmark
        resp = client.post("/api/bookmarks", json={
            "title": "AI News", "url": "https://ai.com", "source": "manual"
        })
        bm_id = resp.json()["id"]

        # Call auto-tag
        resp = client.post(f"/api/bookmarks/{bm_id}/auto-tag", json={})
        assert resp.status_code == 200
        tags = resp.json()["tags"]
        assert len(tags) == 3
        assert tags[0]["name"] == "ai"
