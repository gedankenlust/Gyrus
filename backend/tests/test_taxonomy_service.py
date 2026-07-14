import json
from types import SimpleNamespace

import pytest
from unittest.mock import patch

from models.bookmark import Bookmark
from models.tag import BookmarkTag, Tag
from services import embedding_service, taxonomy_service
from services.llm_service import _build_system_prompt


def _stub_bookmarks(count: int):
    return {
        f"B{index:03d}": SimpleNamespace(
            id=f"bookmark-{index}", title=f"Bookmark {index}",
            url=f"https://example.com/{index}",
            description="", scraped_content="",
        )
        for index in range(1, count + 1)
    }


def test_normalize_tag_names_and_synonyms():
    assert taxonomy_service.normalize_tag_name("  Coworking_Spaces ") == "coworking"
    assert taxonomy_service.canonical_tag_key("developer tools") == taxonomy_service.canonical_tag_key("developer tool")
    assert taxonomy_service.normalize_tag_name("AI assisted development") == "ai-assisted development"
    assert taxonomy_service.normalize_tag_name("far too many words for one useful taxonomy tag") is None


def test_collection_prompt_does_not_claim_there_is_only_one_page():
    prompt = _build_system_prompt('{"id":"B001"}', "Bookmarks", "gyrus://taxonomy",
                                  language="de", context_kind="collection")
    assert "multiple saved bookmark records" in prompt
    assert "currently viewing this one saved page" not in prompt
    assert "BOOKMARK RECORDS" in prompt


@pytest.mark.asyncio
async def test_taxonomy_stream_reports_visible_progress(monkeypatch):
    received = {}

    async def fake_stream(**kwargs):
        received.update(kwargs)
        for piece in ('{"taxonomy":', "[]}"):
            yield piece

    monkeypatch.setattr(taxonomy_service.llm_service.LLMService, "stream_ollama", fake_stream)
    progress = []
    raw = await taxonomy_service._stream_taxonomy(
        "prompt", "records", {"provider": "ollama", "model": "qwen3:8b"},
        "de", "organizing", lambda stage, count: progress.append((stage, count)),
        taxonomy_service._label_schema(["C001", "C002"]),
    )

    assert raw == '{"taxonomy":[]}'
    assert progress == [("organizing", 0), ("organizing", 1), ("organizing", 2)]
    assert received["timeout"] == 600.0
    assert received["context_kind"] == "collection"
    assert received["options"]["num_predict"] == 4096
    assert received["response_format"]["required"] == ["C001", "C002"]
    assert received["response_format"]["additionalProperties"] is False


def test_semantic_clusters_consolidate_singletons():
    vectors = [
        [1.0, 0.0], [0.99, 0.01],
        [0.0, 1.0], [0.01, 0.99],
        [-1.0, 0.0], [-0.99, -0.01],
        [0.0, -1.0], [-0.01, -0.99],
    ]

    groups = taxonomy_service.cluster_vectors(vectors, max_tags=8)

    assert sorted(len(group) for group in groups) == [2, 2, 2, 2]
    assert sorted(index for group in groups for index in group) == list(range(8))


def test_assignment_schema_constrains_every_bookmark_to_known_clusters():
    schema = taxonomy_service._assignment_schema(
        ["B001", "B002"], ["C001", "C002", "C003"]
    )

    assert schema["required"] == ["B001", "B002"]
    assert schema["properties"]["B001"]["enum"] == [
        "C001", "C002", "C003", taxonomy_service.UNTAGGED_CATEGORY,
    ]
    assert schema["additionalProperties"] is False


def test_reusable_labels_reject_generic_and_forced_mixed_topics():
    assert taxonomy_service._is_reusable_label("coworking", "de")
    assert taxonomy_service._is_reusable_label("ki", "de")
    assert taxonomy_service._is_reusable_label("ki dienstleistungen", "de")
    assert taxonomy_service._is_reusable_label("softwareentwicklung", "de")
    assert taxonomy_service._is_reusable_label("persönliche entwicklung", "de")
    assert not taxonomy_service._is_reusable_label("allgemeine links", "de")
    assert not taxonomy_service._is_reusable_label("website", "de")
    assert not taxonomy_service._is_reusable_label("fussball und web scraping", "de")


def test_candidate_aliases_turn_awkward_labels_into_reusable_topics():
    assert taxonomy_service.normalize_tag_name("lokal verwaltete Lesezeichen") == "lesezeichenverwaltung"
    assert taxonomy_service.normalize_tag_name("agentische Entwicklungsumgebungen") == "coding-agenten"
    assert taxonomy_service.normalize_tag_name("Gebrauchtfahrzeuge") == "gebrauchte fahrzeuge"
    assert taxonomy_service.normalize_tag_name("finanzen software") == "finanzsoftware"
    assert taxonomy_service.normalize_tag_name("video bearbeitung") == "videobearbeitung"
    assert taxonomy_service.normalize_tag_name("coworking räume") == "coworking"


def test_cluster_context_includes_url_and_excerpt_for_wordplay_checks():
    bookmarks = [
        SimpleNamespace(
            title="Lucid — Read the machine's mind",
            url="https://lucid.earthpilot.ai",
            description="Watch a language model think.",
            scraped_content="Lucid watches a language model think using Anthropic's Jacobian lens.",
        )
    ]

    context, cluster_ids = taxonomy_service._cluster_context([[0]], bookmarks)
    payload = json.loads(context)

    assert cluster_ids == ["C001"]
    assert payload["items"][0]["url"] == "https://lucid.earthpilot.ai"
    assert "Jacobian lens" in payload["items"][0]["excerpt"]


def test_validation_schema_requires_boolean_for_every_proposal():
    schema = taxonomy_service._validation_schema(["B001", "B004"])

    assert schema["required"] == ["B001", "B004"]
    assert schema["properties"]["B001"] == {"type": "boolean"}


@pytest.mark.asyncio
async def test_taxonomy_embedding_request_releases_model_after_response():
    sent = {}

    class Response:
        def raise_for_status(self):
            return None

        def json(self):
            return {"embeddings": [[1.0, 0.0], [0.0, 1.0]]}

    class Client:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return None

        async def post(self, url, json):
            sent.update(json)
            return Response()

    with patch("services.embedding_service.httpx.AsyncClient", return_value=Client()):
        vectors = await embedding_service.get_embeddings(
            ["first", "second"], model="bge-m3", base_url="http://ollama.test"
        )

    assert vectors == [[1.0, 0.0], [0.0, 1.0]]
    assert sent["keep_alive"] == 0


def test_parse_merges_variants_and_limits_two_tags_per_bookmark():
    keyed = _stub_bookmarks(4)
    raw = json.dumps({"taxonomy": [
        {"name": "developer_tools", "bookmark_ids": ["B001", "B002"]},
        {"name": "developer tool", "bookmark_ids": ["B002", "B003"]},
        {"name": "design", "bookmark_ids": ["B001", "B003", "B004"]},
        {"name": "software", "bookmark_ids": ["B001"]},
    ]})

    draft = taxonomy_service.parse_taxonomy(raw, keyed, max_tags=8, singleton_limit=2, language="en")

    assert len(draft["tags"]) == 2
    tools = next(tag for tag in draft["tags"] if tag["name"] == "developer tools")
    assert tools["bookmark_count"] == 3
    assert draft["assigned"] == 4
    assert all(sum(bookmark_id in tag["bookmark_ids"] for tag in draft["tags"]) <= 2
               for bookmark_id in (item.id for item in keyed.values()))


def test_parse_rejects_fragmented_single_use_taxonomy():
    keyed = _stub_bookmarks(10)
    raw = json.dumps({"taxonomy": [
        {"name": f"topic {index}", "bookmark_ids": [f"B{index:03d}"]}
        for index in range(1, 11)
    ]})

    with pytest.raises(taxonomy_service.TaxonomyQualityError, match="one-off tags"):
        taxonomy_service.parse_taxonomy(raw, keyed, max_tags=20, singleton_limit=2, language="en")


def test_parse_rejects_one_generic_catch_all_tag():
    keyed = _stub_bookmarks(12)
    raw = json.dumps({"taxonomy": [{
        "name": "website", "bookmark_ids": list(keyed),
    }]})

    with pytest.raises(taxonomy_service.TaxonomyQualityError, match="reusable tags"):
        taxonomy_service.parse_taxonomy(raw, keyed, max_tags=12, singleton_limit=3, language="en")


def test_parse_rejects_oversized_catch_all_category():
    keyed = _stub_bookmarks(99)
    raw = json.dumps({"taxonomy": [
        {"name": "webdesign", "bookmark_ids": [f"B{index:03d}" for index in range(1, 40)]},
        {"name": "coworking", "bookmark_ids": ["B040", "B041"]},
        {"name": "baustoffe", "bookmark_ids": ["B042", "B043"]},
    ]})

    with pytest.raises(taxonomy_service.TaxonomyQualityError, match="oversized catch-all"):
        taxonomy_service.parse_taxonomy(raw, keyed, max_tags=12, singleton_limit=3, language="de")


def test_taxonomy_rejects_qwen3_8b_for_global_tagging():
    with pytest.raises(taxonomy_service.TaxonomyQualityError, match="qwen3:8b"):
        taxonomy_service._assert_taxonomy_model_supported({"model": "qwen3:8b"})


def test_parse_accepts_sparse_high_precision_taxonomy():
    keyed = _stub_bookmarks(20)
    raw = json.dumps({"taxonomy": [
        {"name": "coworking", "bookmark_ids": ["B001", "B002"]},
        {"name": "audio frameworks", "bookmark_ids": ["B003", "B004"]},
    ]})

    draft = taxonomy_service.parse_taxonomy(raw, keyed, max_tags=8, singleton_limit=3, language="en")

    assert draft["assigned"] == 4
    assert draft["without_tags"] == 16


def test_parse_accepts_broad_reviewable_taxonomy_for_large_collection():
    keyed = _stub_bookmarks(99)
    raw = json.dumps({"taxonomy": [
        {"name": "ki", "bookmark_ids": [f"B{index:03d}" for index in range(1, 18)]},
        {"name": "webdesign", "bookmark_ids": [f"B{index:03d}" for index in range(18, 37)]},
        {"name": "softwareentwicklung", "bookmark_ids": [f"B{index:03d}" for index in range(37, 49)]},
    ]})

    draft = taxonomy_service.parse_taxonomy(raw, keyed, max_tags=35, singleton_limit=8, language="de")

    assert [tag["name"] for tag in draft["tags"]] == ["webdesign", "ki", "softwareentwicklung"]
    assert draft["assigned"] == 48


def test_apply_draft_is_transactional_and_preserves_manual_assignments(db):
    bookmarks = [
        Bookmark(title=f"Bookmark {index}", url=f"https://apply.example/{index}")
        for index in range(4)
    ]
    db.add_all(bookmarks)
    manual = Tag(name="design", color="#111111", source="manual")
    obsolete = Tag(name="obsolete", color="#222222", source="ai")
    db.add_all([manual, obsolete])
    db.flush()
    db.add(BookmarkTag(bookmark_id=bookmarks[0].id, tag_id=manual.id, source="manual"))
    db.add(BookmarkTag(bookmark_id=bookmarks[1].id, tag_id=obsolete.id, source="ai"))
    db.commit()

    draft = {
        "id": "draft-apply", "language": "en", "total": 4,
        "assigned": 4, "without_tags": 0, "untagged": [],
        "tags": [
            {"id": "T001", "name": "visual design", "bookmark_ids": [bookmarks[0].id, bookmarks[1].id],
             "bookmark_titles": ["Bookmark 0", "Bookmark 1"], "bookmark_count": 2},
            {"id": "T002", "name": "developer tools", "bookmark_ids": [bookmarks[2].id, bookmarks[3].id],
             "bookmark_titles": ["Bookmark 2", "Bookmark 3"], "bookmark_count": 2},
        ],
    }
    taxonomy_service._drafts[draft["id"]] = draft

    result = taxonomy_service.apply_draft(db, draft["id"], [
        {"id": "T001", "name": "design", "enabled": True},
        {"id": "T002", "name": "developer_tools", "enabled": True},
    ])

    assert result == {
        "status": "ok", "tags": 2, "assignments": 4,
        "assigned": 4, "without_tags": 0, "total": 4,
    }
    assert db.query(Tag).filter(Tag.name == "obsolete").first() is None
    assert db.query(Tag).filter(Tag.name == "developer tools").one().source == "ai"
    manual_link = db.query(BookmarkTag).filter(
        BookmarkTag.bookmark_id == bookmarks[0].id,
        BookmarkTag.tag_id == manual.id,
    ).one()
    assert manual_link.source == "manual"
