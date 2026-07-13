from PIL import Image

import json

from services import visual_snapshot_service
from services.visual_snapshot_service import _dominant_colors


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
