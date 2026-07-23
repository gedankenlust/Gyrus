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
    from unittest.mock import patch

    with patch("services.llm_service.LLMService.ask_llm") as mock_ask:
        mock_ask.return_value = '{"tags":[{"name":"ki","evidence":"AI"}]}'
        resp = client.post("/api/bookmarks", json={
            "title": "AI News", "url": "https://ai.com", "source": "manual"
        })
        bm_id = resp.json()["id"]

        resp = client.post(f"/api/bookmarks/{bm_id}/auto-tag", json={})

    assert resp.status_code == 200
    tags = {tag["name"] for tag in resp.json()["tags"]}
    assert tags == {"ki"}
    mock_ask.assert_called_once()


def test_auto_tag_reuses_existing_system_and_preserves_manual_tags(client, db):
    from unittest.mock import patch
    from models.tag import BookmarkTag, Tag

    manual = client.post("/api/tags", json={"name": "design"}).json()
    created = client.post("/api/bookmarks", json={
        "title": "CSS layout guide",
        "url": "https://frontend.example/css-layout",
        "source": "manual",
        "tag_ids": [manual["id"]],
    }).json()

    old_ai = Tag(name="software", color="#888888")
    db.add(old_ai)
    db.flush()
    db.add(BookmarkTag(bookmark_id=created["id"], tag_id=old_ai.id, source="ai"))
    db.commit()

    with patch("services.llm_service.LLMService.ask_llm") as mock_ask:
        mock_ask.return_value = '{"tags":[{"name":"design","evidence":"CSS"}]}'
        response = client.post(f"/api/bookmarks/{created['id']}/auto-tag", json={})

    assert response.status_code == 200
    assert {tag["name"] for tag in response.json()["tags"]} == {"design"}
    sources = {
        row.tag.name: row.source
        for row in db.query(BookmarkTag).filter(BookmarkTag.bookmark_id == created["id"]).all()
    }
    assert sources == {"design": "manual"}


def test_auto_tag_uses_cached_reader_content_without_scraping(client, db):
    from unittest.mock import patch
    from models.bookmark import Bookmark

    created = client.post("/api/bookmarks", json={
        "title": "A vague title",
        "url": "https://example.com/article",
        "source": "manual",
    }).json()
    bookmark = db.query(Bookmark).filter(Bookmark.id == created["id"]).first()
    bookmark.scraped_content = "A practical guide to ceramic glazing and pottery kilns."
    db.commit()

    with (
        patch("services.scraper_service.scraper_service.extract_content") as mock_scrape,
        patch("services.llm_service.LLMService.ask_llm") as mock_ask,
    ):
        mock_ask.return_value = '{"tags":[{"name":"pottery","evidence":"pottery kilns"}]}'
        response = client.post(f"/api/bookmarks/{created['id']}/auto-tag", json={})

    assert response.status_code == 200
    assert {tag["name"] for tag in response.json()["tags"]} == {"pottery"}
    mock_scrape.assert_not_called()
    mock_ask.assert_called_once()


def test_reader_returns_cached_content_without_refetching_site(client, db):
    from unittest.mock import patch
    from models.bookmark import Bookmark

    created = client.post("/api/bookmarks", json={
        "title": "Cached article",
        "url": "https://reader-cache.example/article",
        "source": "manual",
    }).json()
    bookmark = db.query(Bookmark).filter(Bookmark.id == created["id"]).one()
    bookmark.scraped_content = "# Saved heading\n\nLocally stored reader text."
    bookmark.reader_status = "failed"
    db.commit()

    scheduled = []
    with (
        patch("services.scraper_service.scraper_service.extract_content") as scrape,
        patch(
            "routers.bookmarks.bookmark_enrichment_service.schedule_index",
            side_effect=lambda bookmark_id, content: scheduled.append((bookmark_id, content)),
        ),
    ):
        response = client.get(f"/api/bookmarks/{created['id']}/reader")

    assert response.status_code == 200
    assert response.json()["content"] == "# Saved heading\n\nLocally stored reader text."
    scrape.assert_not_called()
    db.refresh(bookmark)
    assert bookmark.reader_status == "ready"
    assert bookmark.index_status == "pending"
    assert scheduled == [(created["id"], "# Saved heading\n\nLocally stored reader text.")]


def test_reader_uses_browser_fallback_for_javascript_page(client, db):
    from unittest.mock import AsyncMock, patch
    from models.bookmark import Bookmark

    created = client.post("/api/bookmarks", json={
        "title": "JavaScript app",
        "url": "https://javascript-reader.example",
        "source": "manual",
    }).json()

    scheduled = []
    with (
        patch(
            "routers.bookmarks.scraper_service.extract_content",
            new=AsyncMock(return_value={"content": "", "error": None}),
        ),
        patch(
            "routers.bookmarks.scraper_service.extract_rendered_content",
            new=AsyncMock(return_value={
                "content": "Rendered heading\n\nVisible application text.",
                "error": None,
            }),
        ) as rendered,
        patch(
            "routers.bookmarks.bookmark_enrichment_service.schedule_index",
            side_effect=lambda bookmark_id, content: scheduled.append((bookmark_id, content)),
        ),
    ):
        response = client.get(f"/api/bookmarks/{created['id']}/reader")

    assert response.status_code == 200
    assert response.json()["content"] == "Rendered heading\n\nVisible application text."
    rendered.assert_awaited_once()
    bookmark = db.query(Bookmark).filter(Bookmark.id == created["id"]).one()
    assert bookmark.scraped_content == "Rendered heading\n\nVisible application text."
    assert bookmark.reader_status == "ready"
    assert scheduled == [
        (created["id"], "Rendered heading\n\nVisible application text.")
    ]


def test_reader_returns_empty_content_when_page_is_not_readable(client):
    from unittest.mock import AsyncMock, patch

    created = client.post("/api/bookmarks", json={
        "title": "Unreadable page",
        "url": "https://unreadable-reader.example",
        "source": "manual",
    }).json()

    with (
        patch(
            "routers.bookmarks.scraper_service.extract_content",
            new=AsyncMock(return_value={"content": "", "error": None}),
        ),
        patch(
            "routers.bookmarks.scraper_service.extract_rendered_content",
            new=AsyncMock(return_value={"content": "", "error": "No visible text"}),
        ),
        patch(
            "routers.bookmarks.bookmark_enrichment_service.schedule_index"
        ) as schedule_index,
    ):
        response = client.get(f"/api/bookmarks/{created['id']}/reader")

    assert response.status_code == 200
    assert response.json() == {"content": ""}
    schedule_index.assert_not_called()


def test_translate_reader_preserves_current_content_and_language(client, db):
    from unittest.mock import patch

    created = client.post("/api/bookmarks", json={
        "title": "Article", "url": "https://reader.example", "source": "manual"
    }).json()

    with patch("services.llm_service.LLMService.ask_llm") as mock_ask:
        mock_ask.return_value = "# Deutsche Überschrift\n\nÜbersetzter Text."
        response = client.post(
            f"/api/bookmarks/{created['id']}/reader/translate",
            json={
                "target_language": "de",
                "content": "# English heading\n\nOriginal text.",
                "provider_config": {"provider": "ollama", "model": "qwen3"},
            },
        )

    assert response.status_code == 200
    assert response.json()["content"].startswith("# Deutsche Überschrift")
    assert mock_ask.call_args.kwargs["context"].startswith("# English heading")
    assert mock_ask.call_args.kwargs["language"] == "de"
    assert mock_ask.call_args.kwargs["think"] is False
