"""Read-later (is_read) status: default unread, toggle, filter, and count."""

BOOKMARK = {"title": "Example", "url": "https://example.com", "source": "manual"}


def test_new_bookmark_is_unread_by_default(client):
    created = client.post("/api/bookmarks", json=BOOKMARK).json()
    assert created["is_read"] is False


def test_mark_as_read_persists(client):
    created = client.post("/api/bookmarks", json=BOOKMARK).json()
    resp = client.put(f"/api/bookmarks/{created['id']}", json={"is_read": True})
    assert resp.status_code == 200
    assert resp.json()["is_read"] is True
    # Re-fetch to confirm it was actually stored.
    assert client.get(f"/api/bookmarks/{created['id']}").json()["is_read"] is True


def test_unread_only_filter(client):
    read = client.post("/api/bookmarks", json={**BOOKMARK, "url": "https://read.com"}).json()
    client.post("/api/bookmarks", json={**BOOKMARK, "url": "https://unread.com"})
    client.put(f"/api/bookmarks/{read['id']}", json={"is_read": True})

    urls = {b["url"] for b in client.get("/api/bookmarks?unread_only=true").json()}
    assert "https://unread.com" in urls
    assert "https://read.com" not in urls


def test_unread_count(client):
    client.post("/api/bookmarks", json={**BOOKMARK, "url": "https://a.com"})
    created = client.post("/api/bookmarks", json={**BOOKMARK, "url": "https://b.com"}).json()
    assert client.get("/api/bookmarks/count-unread").json() == 2
    client.put(f"/api/bookmarks/{created['id']}", json={"is_read": True})
    assert client.get("/api/bookmarks/count-unread").json() == 1


def test_unread_only_in_ids(client):
    read = client.post("/api/bookmarks", json={**BOOKMARK, "url": "https://x.com"}).json()
    unread = client.post("/api/bookmarks", json={**BOOKMARK, "url": "https://y.com"}).json()
    client.put(f"/api/bookmarks/{read['id']}", json={"is_read": True})

    ids = client.get("/api/bookmarks/ids?unread_only=true").json()
    assert unread["id"] in ids
    assert read["id"] not in ids
