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
        resp = client.post("/api/bookmarks", json={
            "title": "AI News", "url": "https://ai.com", "source": "manual"
        })
        bm_id = resp.json()["id"]

        resp = client.post(f"/api/bookmarks/{bm_id}/auto-tag", json={})

    assert resp.status_code == 200
    tags = {tag["name"] for tag in resp.json()["tags"]}
    assert tags == {"ki"}
    mock_ask.assert_not_called()


def test_fast_auto_tag_batch_assigns_one_hundred_without_llm(client, db):
    from unittest.mock import patch

    ids = []
    for index in range(100):
        title = "Coworking Office" if index % 2 == 0 else "How MCP Is Changing WordPress Development"
        url = f"https://bulk-tags-{index}.example"
        ids.append(client.post("/api/bookmarks", json={
            "title": title,
            "url": url,
            "source": "manual",
        }).json()["id"])

    with patch("services.llm_service.LLMService.ask_llm") as mock_ask:
        resp = client.post("/api/bookmarks/auto-tag-fast", json={"bookmark_ids": ids})

    assert resp.status_code == 200
    result = resp.json()
    assert result["total"] == 100
    assert result["tagged"] == 100
    mock_ask.assert_not_called()


def test_fast_auto_tags_assign_multiple_broad_tags(client, db):
    from models.bookmark import Bookmark
    from models.tag import BookmarkTag
    from services import bookmark_service

    created = client.post("/api/bookmarks", json={
        "title": "SubjectiveZero: Agentic editor for creative coding",
        "url": "https://github.com/sxp-studio/subjective-zero",
        "description": "Agentic creative-coding and realtime-VFX harness.",
        "source": "manual",
    }).json()
    bookmark = db.query(Bookmark).filter(Bookmark.id == created["id"]).one()

    bookmark_service.apply_fast_auto_tags(
        db,
        bookmark,
        content="Agents turn visual ideas into hot-reloading Metal nodes for creative coding.",
    )

    tags = {
        row.tag.name
        for row in db.query(BookmarkTag).filter(BookmarkTag.bookmark_id == bookmark.id).all()
    }
    assert {"creative coding", "softwareentwicklung", "ki"}.issubset(tags)


def test_fast_auto_tags_match_whole_words_not_substrings(client, db):
    # "facebook" contains "book" and "booking" starts with it — substring
    # matching used to tag every such page as "lesen" (reading).
    from services.bookmark_service import _fast_tag_names

    class _Page:
        scraped_content = ""
        def __init__(self, title, url, description):
            self.title, self.url, self.description = title, url, description

    facebook = _Page("Facebook Marketing Guide", "https://example.com/fb",
                     "Grow your audience on Facebook")
    assert "lesen" not in _fast_tag_names(facebook)

    booking = _Page("Booking your next trip", "https://example.com/travel",
                    "Hotel booking tips")
    assert "lesen" not in _fast_tag_names(booking)

    # Genuine whole-word and prefix matches still work.
    reading = _Page("A great book about design systems", "https://example.com/read", "")
    assert "lesen" in _fast_tag_names(reading)
    dev = _Page("Moderne Softwareentwicklung", "https://example.com/dev",
                "Artikel über Entwicklungsprozesse")
    assert "softwareentwicklung" in _fast_tag_names(dev)


def test_fast_auto_tag_does_not_trust_generic_url_words(client, db):
    from unittest.mock import patch

    with patch("services.llm_service.LLMService.ask_llm") as mock_ask:
        created = client.post("/api/bookmarks", json={
            "title": "How to read more books",
            "url": "https://ai-software-webdevelopment.example/article",
            "source": "manual",
        }).json()

        response = client.post(f"/api/bookmarks/{created['id']}/auto-tag", json={})

    assert response.status_code == 200
    assert {tag["name"] for tag in response.json()["tags"]} == {"lesen"}
    mock_ask.assert_not_called()


def test_auto_tag_reuses_existing_system_and_preserves_manual_tags(client, db):
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

    response = client.post(f"/api/bookmarks/{created['id']}/auto-tag", json={})

    assert response.status_code == 200
    assert {tag["name"] for tag in response.json()["tags"]} == {"design", "webdesign"}
    sources = {
        row.tag.name: row.source
        for row in db.query(BookmarkTag).filter(BookmarkTag.bookmark_id == created["id"]).all()
    }
    assert sources == {"design": "manual", "webdesign": "ai"}


def test_auto_tag_uses_cached_reader_content_without_scraping_or_llm(client, db):
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
        response = client.post(f"/api/bookmarks/{created['id']}/auto-tag", json={})

    assert response.status_code == 200
    assert response.json()["tags"] == []
    mock_scrape.assert_not_called()
    mock_ask.assert_not_called()


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
