def test_tag_restore_roundtrip(client):
    # Create a bookmark
    bm = client.post("/api/bookmarks", json={"url": "https://x.test", "title": "X"}).json()
    # Create a tag and assign it
    tag = client.post("/api/tags", json={"name": "research", "color": "#f00"}).json()
    client.put(f"/api/bookmarks/{bm['id']}", json={"tag_ids": [tag["id"]]})
    # Confirm assignment
    ids = client.get("/api/bookmarks/ids", params={"tag": "research"}).json()
    assert bm["id"] in ids
    # Delete the tag
    assert client.delete(f"/api/tags/{tag['id']}").status_code == 204
    assert client.get("/api/bookmarks/ids", params={"tag": "research"}).json() == []
    # Restore it
    r = client.post("/api/tags/restore", json={"name": "research", "color": "#f00", "bookmark_ids": [bm["id"]]})
    assert r.status_code == 201, r.text
    # Association is back
    ids2 = client.get("/api/bookmarks/ids", params={"tag": "research"}).json()
    assert bm["id"] in ids2
    # Idempotent: restoring again doesn't duplicate or error
    r2 = client.post("/api/tags/restore", json={"name": "research", "color": "#f00", "bookmark_ids": [bm["id"]]})
    assert r2.status_code == 201
    tags = client.get("/api/tags").json()
    assert len([t for t in tags if t["name"] == "research"]) == 1
