def _mk_bookmark(client, url):
    return client.post("/api/bookmarks", json={"url": url, "title": url}).json()


def _mk_tag(client, name):
    return client.post("/api/tags", json={"name": name, "color": "#00f"}).json()


def _tag_bookmark(client, bm, tag_ids):
    client.put(f"/api/bookmarks/{bm['id']}", json={"tag_ids": tag_ids})


def test_merge_moves_associations_and_deletes_sources(client):
    bm1 = _mk_bookmark(client, "https://a.test")
    bm2 = _mk_bookmark(client, "https://b.test")
    webdev = _mk_tag(client, "webdev")
    web_development = _mk_tag(client, "web development")
    _tag_bookmark(client, bm1, [webdev["id"]])
    _tag_bookmark(client, bm2, [web_development["id"]])

    r = client.post("/api/tags/merge",
                    json={"source_ids": [webdev["id"]], "target_id": web_development["id"]})
    assert r.status_code == 200, r.text

    names = [t["name"] for t in client.get("/api/tags").json()]
    assert "webdev" not in names and "web development" in names
    ids = client.get("/api/bookmarks/ids", params={"tag": "web development"}).json()
    assert set(ids) == {bm1["id"], bm2["id"]}


def test_merge_deduplicates_bookmarks_with_both_tags(client):
    bm = _mk_bookmark(client, "https://c.test")
    a = _mk_tag(client, "ai")
    b = _mk_tag(client, "ki")
    _tag_bookmark(client, bm, [a["id"], b["id"]])

    r = client.post("/api/tags/merge", json={"source_ids": [b["id"]], "target_id": a["id"]})
    assert r.status_code == 200
    ids = client.get("/api/bookmarks/ids", params={"tag": "ai"}).json()
    assert ids.count(bm["id"]) == 1


def test_merge_preserves_manual_tag_source(client, db):
    from models.tag import BookmarkTag

    bm = _mk_bookmark(client, "https://source.test")
    target = _mk_tag(client, "artificial intelligence")
    source = _mk_tag(client, "ai")
    _tag_bookmark(client, bm, [target["id"], source["id"]])
    source_link = db.query(BookmarkTag).filter(
        BookmarkTag.bookmark_id == bm["id"],
        BookmarkTag.tag_id == source["id"],
    ).one()
    source_link.source = "ai"
    db.commit()

    response = client.post(
        "/api/tags/merge",
        json={"source_ids": [source["id"]], "target_id": target["id"]},
    )

    assert response.status_code == 200
    target_link = db.query(BookmarkTag).filter(
        BookmarkTag.bookmark_id == bm["id"],
        BookmarkTag.tag_id == target["id"],
    ).one()
    assert target_link.source == "manual"


def test_merge_rejects_target_in_sources_and_missing_tags(client):
    a = _mk_tag(client, "solo")
    # target within sources only -> nothing to merge
    r = client.post("/api/tags/merge", json={"source_ids": [a["id"]], "target_id": a["id"]})
    assert r.status_code == 400
    r = client.post("/api/tags/merge", json={"source_ids": ["nope"], "target_id": a["id"]})
    assert r.status_code == 404
    r = client.post("/api/tags/merge", json={"source_ids": [a["id"]], "target_id": "nope"})
    assert r.status_code == 404
