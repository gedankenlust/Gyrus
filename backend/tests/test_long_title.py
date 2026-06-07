"""Regression: a very long bookmark title must not crash create or delete.

The Markdown brain builds a filename from the title. An over-long title once
made open()/exists() raise ENAMETOOLONG, surfacing as a 500 — most visibly
when deleting imported bookmarks. Title length must be capped, and brain-sync
failures must never break the core DB operation.
"""


def _create(client, title, url):
    return client.post("/api/bookmarks", json={"title": title, "url": url, "source": "manual"})


def test_create_with_very_long_title(client):
    resp = _create(client, "A" * 400, "https://long-title-create.example.com")
    assert resp.status_code == 201


def test_delete_with_very_long_title(client):
    resp = _create(client, "B" * 400, "https://long-title-delete.example.com")
    assert resp.status_code == 201
    bid = resp.json()["id"]

    del_resp = client.delete(f"/api/bookmarks/{bid}")
    assert del_resp.status_code == 204

    # And it is really gone.
    assert client.get(f"/api/bookmarks/{bid}").status_code == 404


def test_sanitize_caps_filename_bytes():
    from services.brain_sync_service import brain_sync_service
    name = brain_sync_service._sanitize_name("ä" * 500)  # multi-byte chars
    assert len(name.encode("utf-8")) <= 200
