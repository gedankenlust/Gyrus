"""The analysis layer is pure: plain data in, plain data out, no browser."""

import os
import subprocess
import sys
from pathlib import Path

from services.visual_snapshot.analysis.colors import palette_from_pixels
from services.visual_snapshot.analysis.navigation import merge_navigation_groups
from services.visual_snapshot.analysis.network import (
    document_response_headers,
    network_summary,
)
from services.visual_snapshot.analysis.technologies import (
    detect_technologies,
    enrich_technology_signals,
    is_javascript_response,
)

BACKEND_DIR = Path(__file__).resolve().parents[1]


def test_analysis_document_and_imaging_layers_never_import_playwright():
    # Run in a fresh interpreter: other tests import Playwright into this one.
    code = (
        "import sys\n"
        "import services.visual_snapshot.analysis.technologies\n"
        "import services.visual_snapshot.analysis.colors\n"
        "import services.visual_snapshot.analysis.network\n"
        "import services.visual_snapshot.analysis.navigation\n"
        "import services.visual_snapshot.document\n"
        "import services.visual_snapshot.imaging\n"
        "import services.visual_snapshot.persistence\n"
        "loaded = sorted(m for m in sys.modules if m.split('.')[0] == 'playwright')\n"
        "assert not loaded, loaded\n"
    )
    result = subprocess.run(
        [sys.executable, "-c", code],
        cwd=BACKEND_DIR,
        # conftest points GYRUS_DATA_DIR at a temp dir; persistence imports
        # database, which must never resolve to the user's library.
        env={**os.environ, "GYRUS_DATA_DIR": os.environ["GYRUS_DATA_DIR"]},
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode == 0, result.stderr


def test_palette_prefers_design_colors_and_keeps_one_neutral_surface():
    pixels = [(255, 255, 255)] * 600 + [(250, 50, 100)] * 300 + [(20, 120, 220)] * 100

    palette = palette_from_pixels(pixels)

    # White page chrome is kept once, after the real colors, instead of
    # leading the palette.
    assert palette == ["#ff3060", "#1080e0", "#ffffff"]


def test_palette_of_a_monochrome_page_is_its_surface():
    assert palette_from_pixels([(0, 0, 0)] * 10) == ["#000000"]
    assert palette_from_pixels([]) == []


def test_palette_respects_the_color_budget():
    pixels = [(index * 16 % 256, 64, 200 - index) for index in range(40) for _ in range(index + 1)]

    assert len(palette_from_pixels(pixels, max_colors=3)) == 3


def test_network_summary_counts_failures_and_large_requests():
    entries = {
        "a": {"url": "a", "resource_type": "document", "status": 200, "content_length": "1200"},
        "b": {"url": "b", "resource_type": "script", "status": 404, "content_length": "900000"},
        "c": {"url": "c", "resource_type": "script", "failed": True, "failure": "net::ERR_BLOCKED"},
        "d": {"url": "d", "resource_type": "image", "status": 200, "content_length": "not a number"},
    }

    summary = network_summary(entries)

    assert summary["request_count"] == 4
    assert summary["resource_counts"] == [
        {"type": "script", "count": 2},
        {"type": "document", "count": 1},
        {"type": "image", "count": 1},
    ]
    assert [item["url"] for item in summary["failed_requests"]] == ["b", "c"]
    assert summary["large_requests"] == [
        {
            "url": "b", "method": "", "resource_type": "script", "status": 404,
            "content_type": "", "failure": "", "content_length": 900000,
        }
    ]


def test_server_headers_come_only_from_documents_and_are_deduplicated():
    entries = {
        "page": {"resource_type": "document", "server": "Apache", "powered_by": "PleskLin"},
        "frame": {"resource_type": "document", "server": "Apache"},
        "cdn": {"resource_type": "script", "server": "cloudflare"},
    }

    assert document_response_headers(entries) == ["Server: Apache", "X-Powered-By: PleskLin"]


def test_enriched_signals_feed_detection_and_absent_signals_stay_absent():
    assert enrich_technology_signals(
        None, script_markers={"React"}, technology_versions={}, response_headers=["Server: Apache"]
    ) is None

    signals = enrich_technology_signals(
        {"runtime_markers": []},
        script_markers={"Radix UI", "Lucide"},
        technology_versions={"React": "19.1.0"},
        response_headers=["Server: Apache"],
    )
    assert signals["script_content_markers"] == ["Lucide", "Radix UI"]

    names = {item["name"] for item in detect_technologies(signals)}
    assert {"Lucide", "Radix UI", "Apache"} <= names


def test_javascript_responses_are_recognized_by_type_or_extension():
    assert is_javascript_response("https://x.test/app.js?v=2", "")
    assert is_javascript_response("https://x.test/chunk", "Text/JavaScript; charset=utf-8")
    assert is_javascript_response("https://x.test/entry.mjs", "application/octet-stream")
    assert not is_javascript_response("https://x.test/style.css", "text/css")


def test_navigation_merge_adds_new_groups_and_deduplicates_items():
    target = [{"label": "Main", "items": [{"label": "Home", "url": "/", "children": []}]}]
    incoming = [
        {"label": "Main", "items": [{"label": "Home", "url": "/", "children": []}]},
        {"label": None, "items": [{"label": "", "url": "/legal", "children": None}]},
    ]

    merged = merge_navigation_groups(target, incoming)

    assert merged is target
    assert [group["label"] for group in merged] == ["Main", "Navigation"]
    assert len(merged[0]["items"]) == 1
    assert merged[1]["items"] == [{"label": "/legal", "url": "/legal", "children": []}]
