"""Full-text search matches cached page content, not just title/url."""
from services import bookmark_service

BOOKMARK = {"title": "Plain Title", "url": "https://example.com", "source": "manual"}


def test_search_matches_scraped_content(client, db):
    bm = client.post("/api/bookmarks", json=BOOKMARK).json()
    # A word that appears only in the (not-yet-cached) page body → no hit yet.
    assert client.get("/api/search?q=quokka").json() == []

    bookmark_service.store_scraped_content(
        db, bm["id"], "A long article about the quokka, a small friendly marsupial."
    )

    results = client.get("/api/search?q=quokka").json()
    assert any(b["id"] == bm["id"] for b in results)


def test_content_search_ignores_trashed(client, db):
    bm = client.post("/api/bookmarks", json=BOOKMARK).json()
    bookmark_service.store_scraped_content(db, bm["id"], "unique-token-xyzzy in the body")
    assert len(client.get("/api/search?q=xyzzy").json()) == 1

    client.delete(f"/api/bookmarks/{bm['id']}")  # move to trash
    assert client.get("/api/search?q=xyzzy").json() == []
