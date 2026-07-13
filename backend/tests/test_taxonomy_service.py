import json
from types import SimpleNamespace

import pytest

from models.bookmark import Bookmark
from models.tag import BookmarkTag, Tag
from services import taxonomy_service
from services.llm_service import _build_system_prompt


def _stub_bookmarks(count: int):
    return {
        f"B{index:03d}": SimpleNamespace(
            id=f"bookmark-{index}", title=f"Bookmark {index}",
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
