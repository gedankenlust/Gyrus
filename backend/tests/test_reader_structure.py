"""Reader: structured text extraction keeps paragraphs/headings/lists intact
instead of shredding every inline node onto its own line."""
from bs4 import BeautifulSoup
from services.scraper_service import _structured_text


def test_paragraph_stays_on_one_line():
    html = "<div><p>This is a <b>single</b> sentence with <i>inline</i> markup.</p></div>"
    out = _structured_text(BeautifulSoup(html, "html.parser"))
    assert out == "This is a single sentence with inline markup."
    assert "\n" not in out  # not shredded


def test_headings_and_paragraphs_separated():
    html = "<div><h2>Title</h2><p>First para.</p><p>Second para.</p></div>"
    out = _structured_text(BeautifulSoup(html, "html.parser"))
    assert "## Title" in out
    assert "First para." in out
    assert "Second para." in out
    # Blocks separated by a blank line.
    assert "\n\n" in out


def test_list_items_get_bullets():
    html = "<div><ul><li>One</li><li>Two</li></ul></div>"
    out = _structured_text(BeautifulSoup(html, "html.parser"))
    assert "- One" in out
    assert "- Two" in out


def test_no_duplicate_text_from_nested_blocks():
    html = "<article><div><p>Only once.</p></div></article>"
    out = _structured_text(BeautifulSoup(html, "html.parser"))
    assert out.count("Only once.") == 1


def test_fallback_when_no_block_structure():
    html = "this is bare text with no block tags at all, long enough to keep"
    out = _structured_text(BeautifulSoup(html, "html.parser"))
    assert "bare text" in out
