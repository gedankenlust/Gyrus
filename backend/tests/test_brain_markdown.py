"""AI Brain Markdown rendering — Obsidian-friendly notes."""
from datetime import datetime
from types import SimpleNamespace as NS

from services.brain_sync_service import brain_sync_service as svc


def _bookmark(**over):
    base = dict(
        title="GitHub",
        url="https://github.com",
        created_at=datetime(2026, 6, 20),
        description="Where the world builds software.",
        notes=None,
        bookmark_tags=[NS(tag=NS(name="ai")), NS(tag=NS(name="data visualization"))],
        bookmark_notes=[],
    )
    base.update(over)
    return NS(**base)


def test_frontmatter_has_quoted_tags_and_metadata():
    md = svc._render_markdown(_bookmark())
    assert md.startswith("---\n")
    assert 'title: "GitHub"' in md
    assert "url: https://github.com" in md
    assert "created: 2026-06-20" in md
    # Tags are quoted so names with spaces stay valid YAML / Obsidian tags.
    assert 'tags: ["ai", "data visualization"]' in md


def test_body_has_description_link_and_tag_wikilinks():
    md = svc._render_markdown(_bookmark())
    assert "Where the world builds software." in md
    assert "[Open original](https://github.com)" in md
    # Wikilinks build the Obsidian graph.
    assert "[[ai]]" in md and "[[data visualization]]" in md


def test_summary_and_notes_sections_appear_when_present():
    bm = _bookmark(
        notes="My note.",
        bookmark_notes=[NS(source="ai", content="AI summary."),
                        NS(source="user", content="A user note.")],
    )
    md = svc._render_markdown(bm)
    assert "## Summary" in md and "AI summary." in md
    assert "## Notes" in md and "My note." in md and "A user note." in md


def test_no_tags_renders_empty_list_and_no_wikilinks():
    md = svc._render_markdown(_bookmark(bookmark_tags=[]))
    assert "tags: []" in md
    assert "[[" not in md


def test_title_with_quotes_is_escaped():
    md = svc._render_markdown(_bookmark(title='He said "hi"'))
    assert r'title: "He said \"hi\""' in md
