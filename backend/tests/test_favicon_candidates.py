"""Favicon candidate URL resolution.

The key rule: declared icons and the page-relative well-known paths must
resolve against the FULL page URL (with its path), not just the domain root —
otherwise project sites served under a sub-path (e.g. user.github.io/project/)
404 at the domain root and lose their favicon.
"""
import io

import httpx
import pytest
from bs4 import BeautifulSoup
from PIL import Image

from services import metadata_service
from services.metadata_service import _favicon_candidates, _fetch_favicon, _image_extension


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


def _png_bytes() -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (1, 1), (12, 34, 56)).save(buf, format="PNG")
    return buf.getvalue()


def test_svg_favicon_is_not_stored_as_an_image():
    svg = b'<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'
    assert _image_extension(svg, "image/svg+xml") is None
    assert _image_extension(svg, "image/svg+xml; charset=utf-8") is None
    assert _image_extension(svg, "text/plain") is None
    assert _image_extension(svg, "image/png") is None
    assert _image_extension(b"<?xml version='1.0'?><svg></svg>", "application/xml") is None
    # An HTML page that merely contains an <svg> is still not an icon.
    assert _image_extension(b"<html><svg></svg></html>", "text/html") is None
    assert _image_extension(_png_bytes(), "image/png") == ".png"


@pytest.mark.asyncio
async def test_fetch_favicon_skips_svg_and_saves_a_raster(tmp_path, monkeypatch):
    monkeypatch.setattr(metadata_service, "FAVICONS_DIR", tmp_path)
    png = _png_bytes()
    svg = b'<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith(".svg"):
            return httpx.Response(200, content=svg, headers={"content-type": "image/svg+xml"})
        if request.url.path.endswith(".png"):
            return httpx.Response(200, content=png, headers={"content-type": "image/png"})
        return httpx.Response(404)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        filename = await _fetch_favicon("https://example.com/", None, client)

    assert filename is not None and filename.endswith(".png")
    assert (tmp_path / filename).read_bytes() == png
    assert list(tmp_path.glob("*.svg")) == []


@pytest.mark.asyncio
async def test_fetch_favicon_writes_nothing_when_only_svg_is_offered(tmp_path, monkeypatch):
    monkeypatch.setattr(metadata_service, "FAVICONS_DIR", tmp_path)
    svg = b"<svg></svg>"

    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=svg, headers={"content-type": "image/svg+xml"})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        assert await _fetch_favicon("https://example.com/", None, client) is None
    assert list(tmp_path.iterdir()) == []
