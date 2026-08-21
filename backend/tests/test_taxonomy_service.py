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


@pytest.mark.parametrize("input_val, expected", [
    ("  Coworking_Spaces ", "coworking"),
    ("AI assisted development", "ai-assisted development"),
    ("C++", "c++"),
    ("C#", "c#"),
    (".NET", ".net"),
    ("Node.js", "node.js"),
    ("Machine---Learning", "machine---learning"),
    ("  - leading and trailing hyphens -  ", "leading and trailing hyphens"),
    ("web_design", "webdesign"),
    ("100% pure!@#$", "100 pure#"),
    ("groß", "gross"),
    ("MÄRZ", "märz"),
])
def test_normalize_tag_names_and_synonyms(input_val, expected):
    assert taxonomy_service.normalize_tag_name(input_val) == expected

def test_canonical_tag_key():
    assert taxonomy_service.canonical_tag_key("developer tools") == taxonomy_service.canonical_tag_key("developer tool")

def test_normalize_tag_name_limits_and_invalid():
    # Empty string or purely stripped string
    assert taxonomy_service.normalize_tag_name("") is None
    assert taxonomy_service.normalize_tag_name("   -  _   ") is None

    # Exceeds max characters based on constant
    assert taxonomy_service.normalize_tag_name("a" * (taxonomy_service.MAX_NAME_CHARS + 1)) is None
    assert taxonomy_service.normalize_tag_name("a" * taxonomy_service.MAX_NAME_CHARS) == "a" * taxonomy_service.MAX_NAME_CHARS

    # Exceeds max words based on constant
    too_many_words = " ".join([f"w{i}" for i in range(taxonomy_service.MAX_WORDS + 1)])
    max_words = " ".join([f"w{i}" for i in range(taxonomy_service.MAX_WORDS)])
    assert taxonomy_service.normalize_tag_name(too_many_words) is None
    assert taxonomy_service.normalize_tag_name(max_words) == max_words


def test_collection_prompt_does_not_claim_there_is_only_one_page():
    prompt = _build_system_prompt('{"id":"B001"}', "Bookmarks", "gyrus://taxonomy",
                                  language="de", context_kind="collection")
    assert "multiple saved bookmark records" in prompt
    assert "currently viewing this one saved page" not in prompt
    assert "BOOKMARK RECORDS" in prompt


def test_classification_parser_accepts_row_list_from_small_local_models():
    raw = json.dumps([
        {"id": "B001", "tag_1": "ki", "tag_2": "softwareentwicklung", "tag_3": "__NONE__"},
        {"id": "B002", "tag_1": "design", "tag_2": "__NONE__", "tag_3": "__NONE__"},
    ])

    payload = taxonomy_service._classification_payload(raw)

    assert payload["B001_1"] == "ki"
    assert payload["B001_2"] == "softwareentwicklung"
    assert payload["B002_1"] == "design"


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


def test_reusable_labels_reject_generic_and_forced_mixed_topics():
    assert taxonomy_service._is_reusable_label("coworking", "de")
    assert taxonomy_service._is_reusable_label("ki", "de")
    assert taxonomy_service._is_reusable_label("ki dienstleistungen", "de")
    assert taxonomy_service._is_reusable_label("softwareentwicklung", "de")
    assert taxonomy_service._is_reusable_label("persönliche entwicklung", "de")
    assert not taxonomy_service._is_reusable_label("allgemeine links", "de")
    assert not taxonomy_service._is_reusable_label("website", "de")
    assert not taxonomy_service._is_reusable_label("fussball und web scraping", "de")


def test_candidate_aliases_turn_general_awkward_labels_into_reusable_topics():
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


@pytest.mark.asyncio
async def test_generate_draft_classifies_in_bounded_batches_with_stable_labels(monkeypatch, db):
    bookmarks = [
        Bookmark(
            title=f"Bookmark {index}",
            url=f"https://cluster.example/{index}",
            description=f"Topic evidence {index}",
            scraped_content="Cached reader text",
        )
        for index in range(6)
    ]
    db.add_all(bookmarks)
    db.commit()

    async def fake_embeddings(texts, **kwargs):
        return [[1.0, 0.0] for _ in texts]

    calls = []

    async def fake_stream(prompt, records, config, language, stage, progress, response_schema):
        calls.append(stage)
        values = {}
        for key, tag in (
            ("B001", "ki"), ("B002", "ki"),
            ("B003", "softwareentwicklung"), ("B004", "softwareentwicklung"),
            ("B005", "webdesign"), ("B006", "webdesign"),
        ):
            values[key] = tag
        return json.dumps(values)

    monkeypatch.setattr(taxonomy_service.embedding_service, "get_embeddings", fake_embeddings)
    monkeypatch.setattr(taxonomy_service, "_classification_catalog", lambda *_: {
        "ki": "artificial intelligence",
        "softwareentwicklung": "software development",
        "webdesign": "web design",
    })
    monkeypatch.setattr(taxonomy_service, "_stream_taxonomy", fake_stream)

    draft = await taxonomy_service.generate_draft(
        db,
        bookmarks,
        {"provider": "ollama", "model": "small-local-model"},
        "de",
    )

    assert calls == ["assigning"]
    assert draft["assigned"] == 6
    assert draft["without_tags"] == 0
    assert {tag["name"] for tag in draft["tags"]} == {
        "ki", "softwareentwicklung", "webdesign",
    }
    assert all(tag["bookmark_count"] >= 2 for tag in draft["tags"])
    assert {bookmark_id for tag in draft["tags"] for bookmark_id in tag["bookmark_ids"]} == {
        bookmark.id for bookmark in bookmarks
    }
    assert draft["omitted_tags"] == 0


@pytest.mark.asyncio
async def test_generate_draft_prunes_weak_categories_instead_of_failing(monkeypatch, db):
    bookmarks = [
        Bookmark(
            title=f"Bookmark {index}",
            url=f"https://bounded.example/{index}",
            description="Topic evidence",
            scraped_content="Cached reader text",
        )
        for index in range(6)
    ]
    db.add_all(bookmarks)
    db.commit()

    async def fake_embeddings(texts, **kwargs):
        return [[1.0, 0.0] for _ in texts]

    async def fake_stream(prompt, records, config, language, stage, progress, response_schema):
        return json.dumps({
            "B001": "ki", "B002": "ki",
            "B003": "softwareentwicklung", "B004": "softwareentwicklung",
            "B005": "webdesign", "B006": "webdesign",
        })

    monkeypatch.setattr(taxonomy_service.embedding_service, "get_embeddings", fake_embeddings)
    monkeypatch.setattr(taxonomy_service, "taxonomy_limits", lambda _: (2, 2))
    monkeypatch.setattr(taxonomy_service, "_classification_catalog", lambda *_: {
        "ki": "artificial intelligence",
        "softwareentwicklung": "software development",
        "webdesign": "web design",
    })
    monkeypatch.setattr(taxonomy_service, "_stream_taxonomy", fake_stream)

    draft = await taxonomy_service.generate_draft(
        db,
        bookmarks,
        {"provider": "ollama", "model": "small-local-model"},
        "de",
    )

    assert [tag["name"] for tag in draft["tags"]] == ["ki", "softwareentwicklung"]
    assert draft["assigned"] == 6
    assert draft["without_tags"] == 0
    assert draft["omitted_tags"] == 1


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


def test_parse_merges_variants_and_limits_three_tags_per_bookmark():
    keyed = _stub_bookmarks(4)
    raw = json.dumps({"taxonomy": [
        {"name": "developer_tools", "bookmark_ids": ["B001", "B002"]},
        {"name": "developer tool", "bookmark_ids": ["B002", "B003"]},
        {"name": "design", "bookmark_ids": ["B001", "B003", "B004"]},
        {"name": "software", "bookmark_ids": ["B001"]},
    ]})

    draft = taxonomy_service.parse_taxonomy(raw, keyed, max_tags=8, singleton_limit=2, language="en")

    assert len(draft["tags"]) == 3
    tools = next(tag for tag in draft["tags"] if tag["name"] == "developer tools")
    assert tools["bookmark_count"] == 3
    assert draft["assigned"] == 4
    assert all(sum(bookmark_id in tag["bookmark_ids"] for tag in draft["tags"]) <= 3
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


def test_taxonomy_does_not_hard_block_installed_user_model():
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


def test_compact_records_creates_json_lines_and_lookup_dictionary():
    bookmarks = [
        SimpleNamespace(id="bookmark-1", title="First Bookmark", description="Desc 1", scraped_content="Content 1"),
        SimpleNamespace(id="bookmark-2", title="Second Bookmark", description="Desc 2", scraped_content="Content 2")
    ]

    lines, keyed = taxonomy_service.compact_records(bookmarks)

    assert list(keyed.keys()) == ["B001", "B002"]
    assert keyed["B001"] == bookmarks[0]
    assert keyed["B002"] == bookmarks[1]

    json_lines = lines.split("\n")
    assert len(json_lines) == 2

    obj1 = json.loads(json_lines[0])
    assert obj1 == {"id": "B001", "title": "First Bookmark", "description": "Desc 1", "excerpt": "Content 1"}

    obj2 = json.loads(json_lines[1])
    assert obj2 == {"id": "B002", "title": "Second Bookmark", "description": "Desc 2", "excerpt": "Content 2"}


def test_compact_records_truncates_long_fields():
    bookmarks = [
        SimpleNamespace(
            id="bookmark-long",
            title="A" * 150,
            description="B" * 200,
            scraped_content="C" * 350
        )
    ]

    lines, keyed = taxonomy_service.compact_records(bookmarks)

    assert "B001" in keyed

    obj = json.loads(lines)
    assert len(obj["title"]) == 120
    assert obj["title"] == "A" * 120
    assert len(obj["description"]) == 180
    assert obj["description"] == "B" * 180
    assert len(obj["excerpt"]) == taxonomy_service.MAX_EXCERPT_CHARS
    assert obj["excerpt"] == "C" * taxonomy_service.MAX_EXCERPT_CHARS


def test_compact_records_handles_empty_list():
    lines, keyed = taxonomy_service.compact_records([])
    assert lines == ""
    assert keyed == {}


def test_taxonomy_limits_boundary_values():
    # Negative and zero counts default to the minimum values
    assert taxonomy_service.taxonomy_limits(-5) == (6, 2)
    assert taxonomy_service.taxonomy_limits(0) == (6, 2)

    # 1 bookmark is the minimum input for the calculation
    assert taxonomy_service.taxonomy_limits(1) == (6, 2)

    # Moderate count
    assert taxonomy_service.taxonomy_limits(10) == (11, 2)
    assert taxonomy_service.taxonomy_limits(22) == (16, 3)

    # High count scaling normally
    assert taxonomy_service.taxonomy_limits(100) == (35, 7)

    # 130 bookmarks and up hit the maximum tags cap (40)
    assert taxonomy_service.taxonomy_limits(130) == (40, 8)
    assert taxonomy_service.taxonomy_limits(1000) == (40, 8)


def test_limit_categories_caps_the_22_bookmark_case_deterministically():
    grouped = {
        f"tag {index:02d}": [f"B{index + 1:03d}", f"B{(index + 6) % 22 + 1:03d}"]
        for index in range(16)
    }
    grouped["rare tag 1"] = ["B021"]
    grouped["rare tag 2"] = ["B022"]
    primary_counts = {name: len(keys) for name, keys in grouped.items()}
    scores = {name: [0.8] * len(keys) for name, keys in grouped.items()}

    limited, omitted = taxonomy_service._limit_categories(
        grouped, primary_counts, scores, max_tags=16,
    )

    assert len(limited) == 16
    assert omitted == 2
    assert "rare tag 1" not in limited
    assert "rare tag 2" not in limited
