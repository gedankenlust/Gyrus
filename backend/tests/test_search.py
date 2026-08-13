import pytest

BOOKMARK_1 = {"title": "Python Programming", "url": "https://python.org", "source": "manual"}
BOOKMARK_2 = {"title": "FastAPI Framework", "url": "https://fastapi.tiangolo.com", "source": "manual"}
BOOKMARK_3 = {"title": "Test Driven Development", "url": "https://tdd.org", "source": "manual"}

def test_search_endpoint_empty_query(client, db):
    """An empty query should return an empty list."""
    client.post("/api/bookmarks", json=BOOKMARK_1)

    response = client.get("/api/search?q=")
    assert response.status_code == 200
    assert response.json() == []

def test_search_endpoint_basic_match(client, db):
    """A search query matching a bookmark title should return the bookmark."""
    bm = client.post("/api/bookmarks", json=BOOKMARK_1).json()

    response = client.get("/api/search?q=Python")
    assert response.status_code == 200
    results = response.json()
    assert len(results) == 1
    assert results[0]["id"] == bm["id"]
    assert results[0]["title"] == "Python Programming"

def test_search_endpoint_no_match(client, db):
    """A search query that matches nothing should return an empty list."""
    client.post("/api/bookmarks", json=BOOKMARK_1)

    response = client.get("/api/search?q=NonExistentQuery12345")
    assert response.status_code == 200
    assert response.json() == []

def test_search_endpoint_pagination(client, db):
    """The search endpoint should respect limit and offset parameters."""
    # We create a bunch of bookmarks that all match the query
    for i in range(5):
        client.post("/api/bookmarks", json={"title": f"Paginated Item {i}", "url": f"https://page.com/{i}", "source": "manual"})

    response1 = client.get("/api/search?q=Paginated&limit=2&offset=0")
    assert response1.status_code == 200
    results1 = response1.json()
    assert len(results1) == 2

    response2 = client.get("/api/search?q=Paginated&limit=2&offset=2")
    assert response2.status_code == 200
    results2 = response2.json()
    assert len(results2) == 2

    # Check that they don't overlap by ID
    ids1 = {b["id"] for b in results1}
    ids2 = {b["id"] for b in results2}
    assert ids1.isdisjoint(ids2)

def test_search_endpoint_excludes_trashed(client, db):
    """Trashed bookmarks should not appear in search results."""
    bm = client.post("/api/bookmarks", json={"title": "Trash Me", "url": "https://trash.com", "source": "manual"}).json()

    # Should appear initially
    response1 = client.get("/api/search?q=Trash")
    assert response1.status_code == 200
    assert len(response1.json()) == 1

    # Move to trash
    client.delete(f"/api/bookmarks/{bm['id']}")

    # Should not appear now
    response2 = client.get("/api/search?q=Trash")
    assert response2.status_code == 200
    assert response2.json() == []
