from models.tag import BookmarkTag


def _bookmark(client, suffix: str):
    return client.post("/api/bookmarks", json={
        "title": f"Bookmark {suffix}",
        "url": f"https://bulk-tag-{suffix}.example",
        "source": "manual",
    }).json()


def test_bulk_tag_assignment_adds_and_removes_in_one_request(client, db):
    first = _bookmark(client, "one")
    second = _bookmark(client, "two")
    keep = client.post("/api/tags", json={"name": "keep"}).json()
    add = client.post("/api/tags", json={"name": "add"}).json()
    remove = client.post("/api/tags", json={"name": "remove"}).json()

    db.add_all([
        BookmarkTag(bookmark_id=first["id"], tag_id=keep["id"], source="manual"),
        BookmarkTag(bookmark_id=first["id"], tag_id=remove["id"], source="ai"),
        BookmarkTag(bookmark_id=second["id"], tag_id=remove["id"], source="manual"),
    ])
    db.commit()

    response = client.post("/api/tags/assign", json={
        "bookmark_ids": [first["id"], second["id"]],
        "add_tag_ids": [add["id"]],
        "remove_tag_ids": [remove["id"]],
    })

    assert response.status_code == 200
    by_id = {item["id"]: {tag["name"] for tag in item["tags"]} for item in response.json()}
    assert by_id[first["id"]] == {"keep", "add"}
    assert by_id[second["id"]] == {"add"}
    sources = {
        (link.bookmark_id, link.tag_id): link.source
        for link in db.query(BookmarkTag).all()
    }
    assert sources[(first["id"], add["id"])] == "manual"
    assert sources[(second["id"], add["id"])] == "manual"


def test_bulk_tag_assignment_preserves_unmentioned_mixed_tags(client, db):
    first = _bookmark(client, "mixed-one")
    second = _bookmark(client, "mixed-two")
    mixed = client.post("/api/tags", json={"name": "mixed"}).json()
    added = client.post("/api/tags", json={"name": "added"}).json()
    db.add(BookmarkTag(bookmark_id=first["id"], tag_id=mixed["id"], source="manual"))
    db.commit()

    response = client.post("/api/tags/assign", json={
        "bookmark_ids": [first["id"], second["id"]],
        "add_tag_ids": [added["id"]],
    })

    assert response.status_code == 200
    by_id = {item["id"]: {tag["name"] for tag in item["tags"]} for item in response.json()}
    assert by_id[first["id"]] == {"mixed", "added"}
    assert by_id[second["id"]] == {"added"}


def test_bulk_tag_assignment_rejects_unknown_tag(client):
    bookmark = _bookmark(client, "missing-tag")
    response = client.post("/api/tags/assign", json={
        "bookmark_ids": [bookmark["id"]],
        "add_tag_ids": ["missing"],
    })
    assert response.status_code == 404
