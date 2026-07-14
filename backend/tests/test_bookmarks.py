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
        mock_ask.return_value = (
            '{"tags":['
            '{"name":"ai","evidence":"AI News"},'
            '{"name":"future","evidence":"AI News"},'
            '{"name":"tech","evidence":"AI News"}'
            "]}"
        )
        
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


def test_auto_tag_bookmark_respects_language(client, db):
    # language="de" must steer the LLM prompt to German, not just the reply
    # (a new tag's *language* is the model's choice — it can only follow the
    # instruction it was given).
    from unittest.mock import patch
    with patch("services.llm_service.LLMService.ask_llm") as mock_ask:
        mock_ask.return_value = (
            '{"tags":['
            '{"name":"ki","evidence":"KI News"},'
            '{"name":"zukunft","evidence":"KI News"}'
            "]}"
        )

        resp = client.post("/api/bookmarks", json={
            "title": "KI News", "url": "https://ki.example", "source": "manual"
        })
        bm_id = resp.json()["id"]

        resp = client.post(f"/api/bookmarks/{bm_id}/auto-tag", json={"language": "de"})
        assert resp.status_code == 200
        tags = {t["name"] for t in resp.json()["tags"]}
        assert tags == {"ki", "zukunft"}

        sent_prompt = mock_ask.call_args.kwargs.get("prompt") or mock_ask.call_args.args[0]
        assert "Themen-Tags auf Deutsch" in sent_prompt

        # Default (no language) stays English.
        resp = client.post(f"/api/bookmarks/{bm_id}/auto-tag", json={})
        sent_prompt = mock_ask.call_args.kwargs.get("prompt") or mock_ask.call_args.args[0]
        assert "reusable topic tags" in sent_prompt


def test_auto_tag_rejects_unsupported_generic_tags(client, db):
    from unittest.mock import patch

    with patch("services.llm_service.LLMService.ask_llm") as mock_ask:
        mock_ask.return_value = (
            '{"tags":['
            '{"name":"ki","evidence":"How to read more books"},'
            '{"name":"software","evidence":"How to read more books"},'
            '{"name":"webentwicklung","evidence":"How to read more books"},'
            '{"name":"lesen","evidence":"read more books"}'
            "]}"
        )
        created = client.post("/api/bookmarks", json={
            "title": "How to read more books",
            "url": "https://ai-software-webdevelopment.example/article",
            "source": "manual",
        }).json()

        response = client.post(f"/api/bookmarks/{created['id']}/auto-tag", json={})

    assert response.status_code == 200
    assert {tag["name"] for tag in response.json()["tags"]} == {"lesen"}


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
        mock_ask.return_value = (
            '{"tags":[{"name":"webentwicklung","evidence":"CSS layout guide"}]}'
        )
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
        mock_ask.return_value = (
            '{"tags":[{"name":"keramik","evidence":"ceramic glazing"}]}'
        )
        response = client.post(f"/api/bookmarks/{created['id']}/auto-tag", json={})

    assert response.status_code == 200
    assert {tag["name"] for tag in response.json()["tags"]} == {"keramik"}
    mock_scrape.assert_not_called()
    assert "ceramic glazing" in mock_ask.call_args.kwargs["context"]


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
