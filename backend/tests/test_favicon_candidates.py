"""Favicon candidate URL resolution.

The key rule: declared icons and the page-relative well-known paths must
resolve against the FULL page URL (with its path), not just the domain root —
otherwise project sites served under a sub-path (e.g. user.github.io/project/)
404 at the domain root and lose their favicon.
"""
from bs4 import BeautifulSoup

from services.metadata_service import _favicon_candidates


def test_declared_relative_icon_resolves_against_page_path():
    page = "https://user.github.io/project/"
    soup = BeautifulSoup(
        '<link rel="icon" type="image/png" href="favicon-32x32.png">', "html.parser"
    )
    cands = _favicon_candidates(soup, page)
    assert "https://user.github.io/project/favicon-32x32.png" in cands
    # The wrong domain-root resolution must NOT be what we emit for the declared icon.
    assert "https://user.github.io/favicon-32x32.png" not in cands


def test_subpath_wellknown_paths_are_tried():
    page = "https://user.github.io/project/"
    cands = _favicon_candidates(None, page)
    # Both the domain root and the page directory are probed.
    assert "https://user.github.io/favicon.ico" in cands
    assert "https://user.github.io/project/favicon.ico" in cands


def test_root_site_only_uses_domain_root():
    page = "https://example.com/"
    cands = _favicon_candidates(None, page)
    assert "https://example.com/favicon.ico" in cands
    # No redundant page-relative duplicates for a root path.
    assert cands.count("https://example.com/favicon.ico") == 1


def test_apple_touch_icon_is_preferred():
    page = "https://example.com/"
    soup = BeautifulSoup(
        '<link rel="apple-touch-icon" href="/touch.png">'
        '<link rel="icon" href="/fav.png">',
        "html.parser",
    )
    cands = _favicon_candidates(soup, page)
    assert cands[0] == "https://example.com/touch.png"
