from PIL import Image

import json

from services import visual_snapshot_service
from services.visual_snapshot_service import (
    MAX_SCREENSHOT_PIXELS,
    MAX_TECHNOLOGY_SCRIPT_BYTES,
    _attach_issue_evidence,
    _bounded_screenshot_height,
    _declared_script_size,
    _detect_technologies,
    _dominant_colors,
    _is_primary_script_bundle,
    _script_content_markers,
    _script_technology_versions,
    _merge_navigation_groups,
)


def test_navigation_merge_preserves_parent_and_combines_dynamic_submenus():
    target = [
        {
            "label": "Main",
            "items": [
                {"label": "Services", "url": "https://example.com/services", "children": []}
            ],
        }
    ]
    incoming = [
        {
            "label": "Main",
            "items": [
                {
                    "label": "Services",
                    "url": "https://example.com/services",
                    "children": [
                        {"label": "Design", "url": "https://example.com/services/design", "children": []}
                    ],
                }
            ],
        }
    ]

    merged = _merge_navigation_groups(target, incoming)

    assert merged[0]["items"][0]["children"][0]["label"] == "Design"


def test_technology_detection_combines_runtime_generator_and_assets():
    technologies = _detect_technologies(
        {
            "generator": "WordPress 6.8",
            "runtime_markers": ["WordPress", "React"],
            "script_urls": ["https://example.com/wp-content/plugins/app.js"],
            "stylesheet_urls": ["https://cdn.example.com/bootstrap.min.css"],
            "markup_hints": [],
        }
    )

    by_name = {item["name"]: item for item in technologies}
    assert by_name["WordPress"]["confidence"] == "high"
    assert by_name["React"]["category"] == "UI Library"
    assert by_name["Bootstrap"]["confidence"] == "medium"


def test_technology_detection_keeps_unknown_generator_visible():
    technologies = _detect_technologies({"generator": "Acme Site Engine 2.1"})

    assert technologies == [
        {
            "name": "Acme Site Engine 2.1",
            "category": "Site Generator",
            "confidence": "high",
            "evidence": ["Generator: Acme Site Engine 2.1"],
        }
    ]


def test_technology_detection_does_not_invent_a_stack_without_signals():
    assert _detect_technologies(None) == []
    assert _detect_technologies({}) == []


def test_technology_detection_describes_a_handcrafted_static_site():
    technologies = _detect_technologies(
        {
            "runtime_markers": [
                "Custom CSS",
                "CSS Design Tokens",
                "Self-hosted Fonts",
                "Google Analytics 4",
            ],
            "script_content_markers": ["Canvas 2D"],
            "generic_signals": {
                "same_origin_script_count": 5,
                "same_origin_stylesheet_count": 1,
                "module_script_count": 0,
                "semantic_content_element_count": 24,
            },
        }
    )

    by_name = {item["name"]: item for item in technologies}
    assert {
        "Custom CSS",
        "CSS Design Tokens",
        "Self-hosted Fonts",
        "Google Analytics 4",
        "Canvas 2D",
        "Vanilla JavaScript",
        "Static HTML",
    } <= by_name.keys()
    assert by_name["Custom CSS"]["confidence"] == "high"
    assert by_name["Canvas 2D"]["confidence"] == "high"
    assert by_name["Vanilla JavaScript"]["confidence"] == "medium"
    assert by_name["Static HTML"]["confidence"] == "medium"


def test_static_architecture_inference_is_suppressed_for_framework_pages():
    technologies = _detect_technologies(
        {
            "runtime_markers": ["React"],
            "generic_signals": {
                "same_origin_script_count": 4,
                "module_script_count": 0,
                "semantic_content_element_count": 20,
            },
        }
    )

    names = {item["name"] for item in technologies}
    assert "React" in names
    assert "Vanilla JavaScript" not in names
    assert "Static HTML" not in names


def test_technology_detection_ignores_framework_words_in_unrelated_assets():
    technologies = _detect_technologies(
        {
            "script_urls": [
                "https://example.com/articles/react-to-news.js",
                "https://example.com/images/ghost-story.js",
            ],
            "stylesheet_urls": ["https://example.com/vue-gallery.css"],
        }
    )

    assert technologies == []


def test_technology_detection_covers_modern_app_architecture_and_server_headers():
    technologies = _detect_technologies(
        {
            "runtime_markers": [
                "React",
                "TanStack Start",
                "TanStack Router",
                "Tailwind CSS",
                "SSR + Hydration",
                "PWA Manifest",
            ],
            "script_content_markers": ["Radix UI", "Lucide", "Motion"],
            "script_urls": ["https://example.com/assets/index-AbCd1234.js"],
            "markup_hints": ["build=vite-build-assets"],
            "response_headers": ["Server: Apache", "X-Powered-By: PleskLin"],
        }
    )

    by_name = {item["name"]: item for item in technologies}
    assert {
        "React",
        "TanStack Start",
        "TanStack Router",
        "Vite",
        "Tailwind CSS",
        "Radix UI",
        "Lucide",
        "Motion",
        "SSR + Hydration",
        "PWA Manifest",
        "Apache",
        "Plesk",
    } <= by_name.keys()
    assert by_name["Vite"]["confidence"] == "medium"
    assert by_name["Radix UI"]["confidence"] == "high"
    assert by_name["Apache"]["confidence"] == "high"


def test_script_content_markers_are_bounded_and_use_specific_fingerprints():
    content = b"createLucideIcon MotionConfigContext data-radix-collection-item /scripts/plausible.js"

    assert _script_content_markers(content) == ["Radix UI", "Lucide", "Motion", "Plausible"]
    assert _script_content_markers(b"motion is a common English word") == []
    assert _script_content_markers(b"canvas.getContext('2d')") == ["Canvas 2D"]
    assert _script_content_markers(b"gtag('config', measurementId)") == ["Google Analytics 4"]
    assert _script_content_markers(b"x" * 2_000_001) == []


def test_script_body_probe_requires_a_small_declared_size():
    assert _declared_script_size({"content-length": "1024"}) == 1024
    assert _declared_script_size({}) is None
    assert _declared_script_size({"content-length": "chunked"}) is None
    assert _declared_script_size({"content-length": "0"}) is None
    assert _declared_script_size(
        {"content-length": str(MAX_TECHNOLOGY_SCRIPT_BYTES + 1)}
    ) is None


def test_screenshot_height_is_bounded_by_decoded_pixel_budget():
    viewport = {"width": 834, "height": 1112, "device_scale_factor": 2}

    bounded = _bounded_screenshot_height(viewport, 100_000)

    assert bounded >= viewport["height"]
    assert bounded < 20_000
    assert bounded * viewport["width"] * 4 <= MAX_SCREENSHOT_PIXELS


def test_script_technology_versions_require_explicit_package_metadata():
    content = b"version:`19.2.8`,rendererPackageName:`react-dom`"

    assert _script_technology_versions(content) == {"React": "19.2.8"}
    assert _script_technology_versions(b"React 19.2.8 is mentioned in prose") == {}


def test_primary_script_bundle_detection_ignores_unrelated_assets():
    assert _is_primary_script_bundle("https://example.com/assets/index-DH1nRGSA.js")
    assert _is_primary_script_bundle("https://example.com/main-123456.mjs?v=1")
    assert not _is_primary_script_bundle("https://example.com/chunks/index-helper.js")


def test_dominant_colors_prioritize_design_colors_over_page_chrome(tmp_path):
    image_path = tmp_path / "palette.png"
    image = Image.new("RGB", (100, 100), "white")

    for x in range(20):
        for y in range(100):
            image.putpixel((x, y), (255, 48, 96))
    image.save(image_path)

    colors = _dominant_colors(image_path)

    assert colors[0] == "#ff3060"
    assert colors.count("#f0f0f0") <= 1


def test_snapshot_summary_marks_old_desktop_ratio_for_reinspection(tmp_path, monkeypatch):
    monkeypatch.setattr(visual_snapshot_service, "SNAPSHOT_DIR", tmp_path)
    bookmark_dir = tmp_path / "bookmark-1"
    bookmark_dir.mkdir()
    snapshot = {
        "captured_at": "2026-07-13T05:00:00+00:00",
        "viewports": [
            {"name": "desktop", "width": 1440, "height": 1200},
            {"name": "tablet", "width": 834, "height": 1112},
            {"name": "mobile", "width": 390, "height": 844},
        ],
    }
    (bookmark_dir / "visual_snapshot.json").write_text(json.dumps(snapshot))

    captured_at, complete = visual_snapshot_service.snapshot_summary("bookmark-1")

    assert captured_at is not None
    assert complete is False

    snapshot["viewports"][0]["height"] = 900
    (bookmark_dir / "visual_snapshot.json").write_text(json.dumps(snapshot))
    assert visual_snapshot_service.snapshot_summary("bookmark-1")[1] is True


def test_snapshot_runs_are_listed_newest_first_and_pruned(tmp_path, monkeypatch):
    monkeypatch.setattr(visual_snapshot_service, "SNAPSHOT_DIR", tmp_path)
    runs_dir = tmp_path / "bookmark-1" / "runs"
    for index in range(10):
        run_id = f"20260713T1200{index:02d}Z-run"
        run_dir = runs_dir / run_id
        run_dir.mkdir(parents=True)
        (run_dir / "snapshot.json").write_text(json.dumps({
            "run_id": run_id,
            "captured_at": f"2026-07-13T12:00:{index:02d}+00:00",
            "status": "completed",
            "viewports": [{"responsive_issues": [{"id": str(index)}]}],
        }))

    visual_snapshot_service._prune_snapshot_runs("bookmark-1", keep=3)
    runs = visual_snapshot_service.list_snapshot_runs("bookmark-1")

    assert [run["run_id"] for run in runs] == [
        "20260713T120009Z-run",
        "20260713T120008Z-run",
        "20260713T120007Z-run",
    ]
    assert runs[0]["issue_count"] == 1


def test_issue_evidence_is_cropped_into_run_directory(tmp_path):
    screenshot = tmp_path / "mobile.png"
    Image.new("RGB", (780, 1688), "white").save(screenshot)
    issues = [{"x": 10, "y": 20, "width": 100, "height": 60}]

    _attach_issue_evidence(
        issues,
        screenshot,
        tmp_path,
        "bookmark-1",
        "run-1",
        "mobile",
        2,
    )

    assert (tmp_path / "evidence" / "mobile-1.jpg").is_file()
    assert issues[0]["evidence_url"].endswith("/runs/run-1/evidence/mobile-1.jpg")


def test_discard_snapshot_run(tmp_path, monkeypatch):
    monkeypatch.setattr(visual_snapshot_service, "SNAPSHOT_DIR", tmp_path)
    run_dir = tmp_path / "bookmark-1" / "runs" / "run-1"
    run_dir.mkdir(parents=True)

    assert run_dir.exists()
    visual_snapshot_service.discard_snapshot_run("bookmark-1", "run-1")
    assert not run_dir.exists()

    # ensure no errors if the directory doesn't exist
    visual_snapshot_service.discard_snapshot_run("bookmark-1", "run-1")


# --- capture_snapshot with a fake Chromium ----------------------------------

import asyncio
from unittest.mock import AsyncMock

import pytest


class _FakePage:
    def __init__(self, behaviour):
        self.behaviour = behaviour
        self.menus_open = False

    def on(self, *_args):
        pass

    async def goto(self, *_args, **_kwargs):
        if self.behaviour.get("goto_error"):
            raise RuntimeError(self.behaviour["goto_error"])

    async def wait_for_load_state(self, *_args, **_kwargs):
        pass

    async def evaluate(self, expression, *args):
        self.behaviour["events"].append(("evaluate", self.menus_open))
        if self.behaviour.get("hang_evaluate"):
            await asyncio.Event().wait()
        if expression is visual_snapshot_service._VISUAL_EXTRACTOR_JS:
            return {"responsive_issues": [], "navigation": [], "_technology_signals": None}
        return 1200  # document height

    async def screenshot(self, path, clip):
        self.behaviour["events"].append(("screenshot", self.menus_open))
        Image.new("RGB", (clip["width"] // 10, clip["height"] // 10), "white").save(path)

    async def close(self):
        pass


class _FakeContext:
    def __init__(self, behaviour):
        self.behaviour = behaviour

    async def route(self, *_args):
        pass

    async def new_page(self):
        page = _FakePage(self.behaviour)
        self.behaviour["pages"].append(page)
        return page

    async def close(self):
        pass


class _FakeBrowser:
    def __init__(self, behaviour):
        self.behaviour = behaviour

    async def new_context(self, **_kwargs):
        return _FakeContext(self.behaviour)

    async def close(self):
        pass


def _fake_playwright(behaviour):
    class Chromium:
        async def launch(self, **_kwargs):
            return _FakeBrowser(behaviour)

    class Manager:
        chromium = Chromium()

        async def __aenter__(self):
            return self

        async def __aexit__(self, *_args):
            return False

    return lambda: Manager()


@pytest.fixture
def fake_capture(tmp_path, monkeypatch):
    from services.site_structure_service import site_structure_service

    behaviour = {"events": [], "pages": []}
    monkeypatch.setattr(visual_snapshot_service, "SNAPSHOT_DIR", tmp_path)
    monkeypatch.setattr(visual_snapshot_service, "validate_outbound_url", AsyncMock())
    monkeypatch.setattr("playwright.async_api.async_playwright", _fake_playwright(behaviour))
    monkeypatch.setattr(site_structure_service, "data_for_url", AsyncMock(return_value={}))
    monkeypatch.setattr(site_structure_service, "snapshot_payload", lambda data: {"pages": []})

    async def navigation(page):
        page.behaviour["events"].append(("navigation", page.menus_open))
        page.menus_open = True  # exploring hovers and clicks menus open
        return [{"label": "Main", "items": []}]

    monkeypatch.setattr(visual_snapshot_service, "_capture_rendered_navigation", navigation)
    return behaviour


@pytest.mark.asyncio
async def test_navigation_is_explored_after_screenshot_and_extraction(fake_capture):
    snapshot = await visual_snapshot_service.capture_snapshot("bm", "https://design.example/")

    assert snapshot["status"] == "completed", snapshot["errors"]
    assert snapshot["promoted"] is True
    assert snapshot["navigation"] == [{"label": "Main", "items": []}]
    desktop_events = []
    for event in fake_capture["events"]:
        desktop_events.append(event)
        if event[0] == "navigation":
            break
    # Height, screenshot and extractor all ran with menus still closed.
    assert desktop_events == [
        ("evaluate", False), ("screenshot", False), ("evaluate", False), ("navigation", False),
    ]
    assert [e for e in fake_capture["events"] if e[0] == "navigation"] == [("navigation", False)]
    assert visual_snapshot_service.read_snapshot("bm")["run_id"] == snapshot["run_id"]


@pytest.mark.asyncio
async def test_failed_capture_keeps_current_snapshot_and_is_listed(fake_capture):
    good = await visual_snapshot_service.capture_snapshot("bm", "https://design.example/")
    fake_capture["goto_error"] = "net::ERR_TUNNEL_CONNECTION_FAILED"

    failed = await visual_snapshot_service.capture_snapshot("bm", "https://design.example/")

    assert failed["status"] == "failed"
    assert failed["promoted"] is False
    assert failed["viewports"] == []
    current = visual_snapshot_service.read_snapshot("bm")
    assert current["run_id"] == good["run_id"]
    assert len(current["viewports"]) == len(visual_snapshot_service.VIEWPORTS)
    runs = {run["run_id"]: run["status"] for run in visual_snapshot_service.list_snapshot_runs("bm")}
    assert runs == {good["run_id"]: "completed", failed["run_id"]: "failed"}


@pytest.mark.asyncio
async def test_failed_runs_never_prune_the_current_snapshot_run(fake_capture, monkeypatch):
    monkeypatch.setattr(visual_snapshot_service, "MAX_SNAPSHOT_RUNS", 2)
    good = await visual_snapshot_service.capture_snapshot("bm", "https://design.example/")
    fake_capture["goto_error"] = "offline"
    for _ in range(3):
        await visual_snapshot_service.capture_snapshot("bm", "https://design.example/")

    run_ids = [run["run_id"] for run in visual_snapshot_service.list_snapshot_runs("bm")]
    assert good["run_id"] in run_ids
    screenshot = visual_snapshot_service._run_dir("bm", good["run_id"]) / "desktop.png"
    assert screenshot.exists()


@pytest.mark.asyncio
async def test_failed_capture_job_reports_an_error(fake_capture):
    from services import visual_snapshot_job_service

    fake_capture["goto_error"] = "net::ERR_NAME_NOT_RESOLVED"
    await visual_snapshot_job_service.start("bm", "https://design.example/")
    await visual_snapshot_job_service.job._task

    status = visual_snapshot_job_service.get_status()
    assert status["running"] is False
    assert status["stage"] == "failed"
    assert "ERR_NAME_NOT_RESOLVED" in status["error"]
    assert status["snapshot"]["status"] == "failed"
    assert visual_snapshot_service.read_snapshot("bm") is None


@pytest.mark.asyncio
async def test_hanging_page_script_cannot_block_the_capture(fake_capture, monkeypatch):
    monkeypatch.setattr(visual_snapshot_service, "EVALUATE_TIMEOUT_SECONDS", 0.01)
    fake_capture["hang_evaluate"] = True

    snapshot = await asyncio.wait_for(
        visual_snapshot_service.capture_snapshot("bm", "https://design.example/"), timeout=5
    )

    assert snapshot["status"] == "failed"
    assert len(snapshot["errors"]) == len(visual_snapshot_service.VIEWPORTS)


@pytest.mark.asyncio
async def test_navigation_failure_keeps_the_captured_viewport(fake_capture, monkeypatch):
    async def broken(page):
        raise RuntimeError("menu exploded")

    monkeypatch.setattr(visual_snapshot_service, "_capture_rendered_navigation", broken)
    snapshot = await visual_snapshot_service.capture_snapshot("bm", "https://design.example/")
    assert snapshot["status"] == "completed"
    assert snapshot["navigation"] == []
    assert [v["name"] for v in snapshot["viewports"]][0] == "desktop"


def test_atomic_write_keeps_previous_file_when_replace_fails(tmp_path, monkeypatch):
    import os
    from services import atomic_write

    target = tmp_path / "visual_snapshot.json"
    target.write_text('{"run_id": "old"}')

    def failing_replace(*_args):
        raise OSError("disk full")

    monkeypatch.setattr(atomic_write.os, "replace", failing_replace)
    with pytest.raises(OSError):
        atomic_write.atomic_write_text(target, '{"run_id": "new"}')
    monkeypatch.undo()

    assert target.read_text() == '{"run_id": "old"}'
    assert os.listdir(tmp_path) == ["visual_snapshot.json"]
    atomic_write.atomic_write_text(target, '{"run_id": "new"}')
    assert json.loads(target.read_text()) == {"run_id": "new"}


def test_site_structure_cache_is_written_atomically(tmp_path, monkeypatch):
    from services import site_structure_service as module

    service = module.SiteStructureService()
    monkeypatch.setattr(service, "cache_dir", tmp_path)
    written = []
    real = module.atomic_write_text
    monkeypatch.setattr(module, "atomic_write_text", lambda path, text: (written.append(path), real(path, text)))

    service._write_cache("bm", "https://design.example/", {"version": module.CACHE_VERSION})

    assert written == [service._cache_path("bm", "https://design.example/")]
    assert service._read_cache("bm", "https://design.example/") == {"version": module.CACHE_VERSION}
