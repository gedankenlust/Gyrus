from PIL import Image

import json

from services import visual_snapshot_service
from services.visual_snapshot_service import _attach_issue_evidence, _dominant_colors


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
