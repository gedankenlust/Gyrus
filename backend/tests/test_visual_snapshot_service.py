from PIL import Image

import json

from services import visual_snapshot_service
from services.visual_snapshot_service import (
    _attach_issue_evidence,
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
