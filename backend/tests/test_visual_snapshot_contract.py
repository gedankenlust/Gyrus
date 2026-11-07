"""The stored snapshot must keep the keys the Swift app decodes.

The key lists below are derived from the CodingKeys (or, where a DTO has
none, the property names) in Gyrus/Models/VisualSnapshotDTOs.swift. Only
non-optional Swift properties are "required": a missing one makes the whole
snapshot fail to decode. Optional ones are listed too, because a renamed key
silently empties a section of the Design inspector.
"""

import copy
import json
import re
from pathlib import Path
from unittest.mock import AsyncMock

import pytest
from PIL import Image

from services import visual_snapshot_job_service, visual_snapshot_service
from services.visual_snapshot import browser, capture, persistence
from services.visual_snapshot.extraction import VISUAL_EXTRACTOR_JS

SWIFT_DTOS = Path(__file__).resolve().parents[2] / "Gyrus" / "Models" / "VisualSnapshotDTOs.swift"

# (required, optional) per DTO.
SNAPSHOT_KEYS = (
    {"bookmark_id", "url", "title", "captured_at", "viewports"},
    {"schema_version", "run_id", "status", "navigation", "site_structure", "errors"},
)
NAVIGATION_GROUP_KEYS = ({"label", "items"}, set())
NAVIGATION_ITEM_KEYS = ({"label", "children"}, {"url"})
SITE_STRUCTURE_KEYS = (
    {
        "origin", "listed_page_count", "sitemap_page_count", "crawled_page_count",
        "sitemap_sources", "pages", "page_tree", "errors",
    },
    {"crawl_limit", "crawl_limit_reached", "sitemap_limit", "sitemap_limit_reached"},
)
SITE_PAGE_KEYS = ({"url", "path", "title", "source"}, set())
SITE_NODE_KEYS = ({"label", "path", "children"}, {"url", "source"})
RUN_KEYS = ({"run_id"}, {"captured_at", "status", "viewport_count", "issue_count"})
ERROR_KEYS = (set(), {"viewport", "message"})
JOB_STATUS_KEYS = ({"running"}, {"bookmark_id", "stage", "completed", "total", "error", "snapshot"})
VIEWPORT_KEYS = (
    {
        "name", "width", "height", "screenshot", "screenshot_url", "dominant_colors",
        "observed_colors", "observed_fonts", "structure",
    },
    {
        "page_title", "meta_description", "element_samples", "seo", "assets", "accessibility",
        "css_variables", "technologies", "network", "console_messages", "responsive_issues",
    },
)
TECHNOLOGY_KEYS = ({"name", "category", "confidence", "evidence"}, {"version"})
ISSUE_KEYS = (
    {"id", "kind", "severity", "title", "detail", "selector_hint", "text", "x", "y", "width", "height", "metric"},
    {"evidence_url"},
)
STRUCTURE_KEYS = ({"h1", "h2", "links", "buttons", "images", "svgs", "forms"}, set())
SEO_KEYS = (
    set(),
    {
        "title", "meta_description", "canonical", "language", "robots", "open_graph",
        "twitter", "json_ld", "headings", "internal_links", "external_links",
    },
)
ACCESSIBILITY_KEYS = (set(), {"missing_alt_images", "empty_buttons", "unlabeled_inputs", "heading_skips"})
CSS_VARIABLE_KEYS = ({"name", "value"}, set())
NETWORK_KEYS = (set(), {"request_count", "resource_counts", "failed_requests", "large_requests"})
RESOURCE_COUNT_KEYS = ({"type", "count"}, set())
ELEMENT_SAMPLE_KEYS = (
    {
        "tag", "selector_hint", "text", "x", "y", "width", "height", "display", "position",
        "font_family", "font_size", "font_weight", "line_height", "color", "background_color",
        "border_radius", "box_shadow", "letter_spacing", "text_transform", "margin", "padding",
    },
    set(),
)

ALL_KEY_SETS = [
    SNAPSHOT_KEYS, NAVIGATION_GROUP_KEYS, NAVIGATION_ITEM_KEYS, SITE_STRUCTURE_KEYS, SITE_PAGE_KEYS,
    SITE_NODE_KEYS, RUN_KEYS, ERROR_KEYS, JOB_STATUS_KEYS, VIEWPORT_KEYS, TECHNOLOGY_KEYS, ISSUE_KEYS,
    STRUCTURE_KEYS, SEO_KEYS, ACCESSIBILITY_KEYS, CSS_VARIABLE_KEYS, NETWORK_KEYS, RESOURCE_COUNT_KEYS,
    ELEMENT_SAMPLE_KEYS,
]


def _assert_shape(document: dict, keys: tuple[set, set], where: str) -> None:
    """Required keys must be present and non-null; Swift decodes optionals as nil."""
    required, _optional = keys
    missing = {key for key in required if document.get(key) is None}
    assert not missing, f"{where} lacks required keys {sorted(missing)}"


# What VISUAL_EXTRACTOR_JS returns for a small page, trimmed to one item per list.
EXTRACTION_FIXTURE = {
    "page_title": "Design Example",
    "meta_description": "A page with a palette.",
    "seo": {
        "title": "Design Example",
        "meta_description": "A page with a palette.",
        "canonical": "https://design.example/",
        "language": "en",
        "robots": "",
        "open_graph": [{"name": "og:title", "content": "Design Example"}],
        "twitter": [],
        "json_ld": [],
        "headings": [{"level": 1, "text": "Welcome"}],
        "internal_links": 3,
        "external_links": 1,
    },
    "assets": {
        "images": [{
            "kind": "image", "url": "https://design.example/hero.png", "alt": "", "width": 800,
            "height": 400, "loading": "lazy", "selector_hint": ".hero",
        }],
        "icons": [{"kind": "icon", "url": "https://design.example/favicon.ico", "rel": "icon", "sizes": "", "type": ""}],
        "stylesheets": [{"kind": "stylesheet", "url": "https://design.example/site.css", "media": ""}],
        "scripts": [{"kind": "script", "url": "https://design.example/app.js", "async": False, "defer": True, "type": ""}],
    },
    "accessibility": {
        "missing_alt_images": [{"kind": "image", "url": "https://design.example/hero.png", "alt": ""}],
        "empty_buttons": [{"selector_hint": ".icon", "text": "", "aria_label": ""}],
        "unlabeled_inputs": [],
        "heading_skips": [{"from": {"level": 1, "text": "Welcome"}, "to": {"level": 3, "text": "Deep"}}],
    },
    "css_variables": [{"name": "--brand", "value": "#ff3060"}, {"name": "--tw-ring", "value": "0 0 #0000"}],
    "structure": {"h1": ["Welcome"], "h2": [], "links": 4, "buttons": 1, "images": 1, "svgs": 0, "forms": 0},
    "observed_colors": ["rgb(255, 48, 96)", "rgb(255, 255, 255)"],
    "observed_fonts": ["Inter, sans-serif"],
    "element_samples": [{
        "tag": "h1", "selector_hint": "h1", "text": "Welcome", "x": 0, "y": 0, "width": 400, "height": 60,
        "display": "block", "position": "static", "font_family": "Inter, sans-serif", "font_size": "48px",
        "font_weight": "700", "line_height": "56px", "color": "rgb(255, 48, 96)",
        "background_color": "rgba(0, 0, 0, 0)", "border_radius": "0px", "box_shadow": "none",
        "letter_spacing": "normal", "text_transform": "none", "margin": "0px 0px 0px 0px",
        "padding": "0px 0px 0px 0px",
    }],
    "responsive_issues": [{
        "id": "small_text:p:10:20", "kind": "small_text", "severity": "low", "title": "Very small text",
        "detail": "This text may be difficult to read.", "selector_hint": "p", "text": "fine print",
        "x": 10, "y": 20, "width": 100, "height": 30, "metric": "11px",
    }],
    "_technology_signals": {
        "generator": "",
        "runtime_markers": ["Custom CSS"],
        "script_urls": ["https://design.example/app.js"],
        "stylesheet_urls": ["https://design.example/site.css"],
        "markup_hints": [],
        "generic_signals": {"same_origin_script_count": 1, "module_script_count": 0,
                            "semantic_content_element_count": 8},
    },
    "navigation": [{"label": "legacy", "items": []}],
}

CRAWL_FIXTURE = {
    "origin": "https://design.example",
    "captured_at": 1_762_500_000,
    "pages": [
        {"url": "https://design.example/", "path": "/", "title": "Home"},
        {"url": "https://design.example/about", "path": "/about", "title": "About"},
    ],
    "limit": 80,
    "limit_reached": False,
    "sitemap_pages": 1,
    "sitemap_page_urls": ["https://design.example/pricing"],
    "sitemap_limit": 10_000,
    "sitemap_limit_reached": False,
    "sitemap_sources": ["https://design.example/sitemap.xml"],
    "errors": [],
}

NAVIGATION_FIXTURE = [{
    "label": "Main",
    "items": [{"label": "Services", "url": "https://design.example/services", "children": [
        {"label": "Design", "url": "https://design.example/services/design", "children": []},
    ]}],
}]


class _Page:
    def __init__(self, failing: set[str], viewport_name: str):
        self.failing = failing
        self.viewport_name = viewport_name

    def on(self, *_args):
        pass

    async def goto(self, *_args, **_kwargs):
        if self.viewport_name in self.failing:
            raise RuntimeError(f"net::ERR_CONNECTION_RESET on {self.viewport_name}")

    async def wait_for_load_state(self, *_args, **_kwargs):
        pass

    async def evaluate(self, expression, *_args):
        if expression is VISUAL_EXTRACTOR_JS:
            return copy.deepcopy(EXTRACTION_FIXTURE)
        return 1200

    async def screenshot(self, path, clip):
        image = Image.new("RGB", (clip["width"] // 4, clip["height"] // 4), "white")
        for x in range(image.width // 3):
            for y in range(image.height):
                image.putpixel((x, y), (255, 48, 96))
        image.save(path)

    async def close(self):
        pass


def _fake_playwright(failing: set[str]):
    class Context:
        def __init__(self, viewport):
            self.viewport = viewport

        async def route(self, *_args):
            pass

        async def new_page(self):
            width = self.viewport["width"]
            name = {1440: "desktop", 834: "tablet", 390: "mobile"}[width]
            return _Page(failing, name)

        async def close(self):
            pass

    class Browser:
        async def new_context(self, **kwargs):
            return Context(kwargs["viewport"])

        async def close(self):
            pass

    class Chromium:
        async def launch(self, **_kwargs):
            return Browser()

    class Manager:
        chromium = Chromium()

        async def __aenter__(self):
            return self

        async def __aexit__(self, *_args):
            return False

    return lambda: Manager()


@pytest.fixture
def fixture_capture(tmp_path, monkeypatch):
    from services.site_structure_service import site_structure_service

    failing: set[str] = set()
    monkeypatch.setattr(persistence, "SNAPSHOT_DIR", tmp_path)
    # Both the pre-flight check in capture and the request guard in browser
    # bound the name at import, so each needs its own patch.
    monkeypatch.setattr(capture, "validate_outbound_url", AsyncMock())
    monkeypatch.setattr(browser, "validate_outbound_url", AsyncMock())
    monkeypatch.setattr("playwright.async_api.async_playwright", _fake_playwright(failing))
    # The real snapshot_payload runs on a fixture crawl.
    monkeypatch.setattr(site_structure_service, "data_for_url", AsyncMock(return_value=CRAWL_FIXTURE))

    async def navigation(_page):
        return copy.deepcopy(NAVIGATION_FIXTURE)

    monkeypatch.setattr(capture, "capture_rendered_navigation", navigation)
    return failing


def _walk_navigation(items: list[dict]):
    for item in items:
        yield item
        yield from _walk_navigation(item["children"])


def _assert_snapshot_contract(snapshot: dict) -> None:
    _assert_shape(snapshot, SNAPSHOT_KEYS, "snapshot")
    for group in snapshot["navigation"]:
        _assert_shape(group, NAVIGATION_GROUP_KEYS, "navigation group")
        for item in _walk_navigation(group["items"]):
            _assert_shape(item, NAVIGATION_ITEM_KEYS, "navigation item")

    structure = snapshot["site_structure"]
    _assert_shape(structure, SITE_STRUCTURE_KEYS, "site_structure")
    for page in structure["pages"]:
        _assert_shape(page, SITE_PAGE_KEYS, "site page")
    nodes = list(structure["page_tree"])
    while nodes:
        node = nodes.pop()
        _assert_shape(node, SITE_NODE_KEYS, "site page node")
        nodes.extend(node["children"])

    for error in snapshot["errors"]:
        _assert_shape(error, ERROR_KEYS, "error")
        assert set(error) <= ERROR_KEYS[1]

    for viewport in snapshot["viewports"]:
        where = f"viewport {viewport['name']}"
        _assert_shape(viewport, VIEWPORT_KEYS, where)
        assert "_technology_signals" not in viewport
        assert "navigation" not in viewport
        _assert_shape(viewport["structure"], STRUCTURE_KEYS, f"{where}.structure")
        _assert_shape(viewport["seo"], SEO_KEYS, f"{where}.seo")
        _assert_shape(viewport["accessibility"], ACCESSIBILITY_KEYS, f"{where}.accessibility")
        _assert_shape(viewport["network"], NETWORK_KEYS, f"{where}.network")
        for count in viewport["network"]["resource_counts"]:
            _assert_shape(count, RESOURCE_COUNT_KEYS, f"{where}.network.resource_counts")
        for technology in viewport["technologies"]:
            _assert_shape(technology, TECHNOLOGY_KEYS, f"{where}.technologies")
        for issue in viewport["responsive_issues"]:
            _assert_shape(issue, ISSUE_KEYS, f"{where}.responsive_issues")
        for variable in viewport["css_variables"]:
            _assert_shape(variable, CSS_VARIABLE_KEYS, f"{where}.css_variables")
        for sample in viewport["element_samples"]:
            _assert_shape(sample, ELEMENT_SAMPLE_KEYS, f"{where}.element_samples")
        assert all(re.fullmatch(r"#[0-9a-f]{6}", color) for color in viewport["dominant_colors"])
        assert isinstance(viewport["width"], int) and isinstance(viewport["height"], int)


@pytest.mark.asyncio
async def test_captured_snapshot_matches_the_swift_dtos(fixture_capture):
    snapshot = await visual_snapshot_service.capture_snapshot("bm", "https://design.example/", title="Example")

    # What the API returns is what was stored; both must decode.
    stored = visual_snapshot_service.read_snapshot("bm")
    assert stored == json.loads(json.dumps(snapshot))
    _assert_snapshot_contract(stored)

    assert stored["status"] == "completed"
    assert stored["schema_version"] == visual_snapshot_service.SNAPSHOT_SCHEMA_VERSION
    assert stored["navigation"] == NAVIGATION_FIXTURE
    assert [viewport["name"] for viewport in stored["viewports"]] == ["desktop", "tablet", "mobile"]
    desktop = stored["viewports"][0]
    assert desktop["screenshot_url"] == f"/api/files/visual-snapshots/bm/runs/{stored['run_id']}/desktop.png"
    assert desktop["responsive_issues"][0]["evidence_url"].endswith("/evidence/desktop-1.jpg")
    assert desktop["dominant_colors"][0] == "#ff3060"
    assert {"Custom CSS", "Vanilla JavaScript", "Static HTML"} <= {
        technology["name"] for technology in desktop["technologies"]
    }
    assert stored["site_structure"]["listed_page_count"] == 3

    runs = visual_snapshot_service.list_snapshot_runs("bm")
    assert len(runs) == 1
    _assert_shape(runs[0], RUN_KEYS, "run")
    assert runs[0]["viewport_count"] == 3
    assert runs[0]["issue_count"] == 3


@pytest.mark.asyncio
async def test_partial_snapshot_explains_the_missing_viewport(fixture_capture):
    fixture_capture.add("tablet")

    snapshot = await visual_snapshot_service.capture_snapshot("bm", "https://design.example/")

    _assert_snapshot_contract(snapshot)
    assert snapshot["status"] == "partial"
    assert snapshot["promoted"] is True
    assert [viewport["name"] for viewport in snapshot["viewports"]] == ["desktop", "mobile"]
    assert snapshot["errors"] == [
        {"viewport": "tablet", "message": "net::ERR_CONNECTION_RESET on tablet"}
    ]


@pytest.mark.asyncio
async def test_job_status_carries_a_decodable_snapshot(fixture_capture):
    await visual_snapshot_job_service.start("bm", "https://design.example/")
    await visual_snapshot_job_service.job._task

    status = visual_snapshot_job_service.get_status()
    _assert_shape(status, JOB_STATUS_KEYS, "job status")
    assert status["stage"] == "finished"
    _assert_snapshot_contract(status["snapshot"])


def test_the_page_extractor_emits_the_keys_the_app_requires():
    # Keys produced inside the page rather than by Python.
    for key in (
        VIEWPORT_KEYS[0] - {"name", "width", "height", "screenshot", "screenshot_url", "dominant_colors"}
    ) | ELEMENT_SAMPLE_KEYS[0] | STRUCTURE_KEYS[0] | ISSUE_KEYS[0]:
        assert re.search(rf"\b{key}\b\s*[:,]", VISUAL_EXTRACTOR_JS), key


@pytest.mark.skipif(not SWIFT_DTOS.exists(), reason="Swift sources not checked out")
def test_key_lists_still_match_the_swift_dtos():
    swift = SWIFT_DTOS.read_text(encoding="utf-8")
    for required, optional in ALL_KEY_SETS:
        for key in required | optional:
            assert re.search(rf'"{key}"|\b(?:case|let)\s[^\n]*\b{key}\b', swift), (
                f"{key} no longer appears in VisualSnapshotDTOs.swift; update this contract test"
            )
