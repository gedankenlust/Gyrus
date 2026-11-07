"""Artifacts derived from a viewport screenshot on disk.

Decoding a full-page screenshot (up to MAX_SCREENSHOT_PIXELS) is CPU-bound,
so the capture runs these functions through ``asyncio.to_thread``.
"""

from pathlib import Path
from typing import Any

from PIL import Image

from services.visual_snapshot.analysis.colors import palette_from_pixels
from services.visual_snapshot.persistence import run_file_url

MAX_EVIDENCE_CROPS = 16
EVIDENCE_PADDING_CSS_PX = 24
EVIDENCE_THUMBNAIL_SIZE = (720, 420)
PALETTE_SAMPLE_SIZE = (240, 240)


def dominant_colors(path: Path, max_colors: int = 8) -> list[str]:
    try:
        with Image.open(path) as img:
            img = img.convert("RGB")
            # The same pixel budget as a 240 x 240 sample, spread over the page
            # in its own proportions: thumbnail() into a square would turn a
            # full-page capture of a long site into a strip a few pixels wide.
            budget = PALETTE_SAMPLE_SIZE[0] * PALETTE_SAMPLE_SIZE[1]
            factor = min(1.0, (budget / max(1, img.width * img.height)) ** 0.5)
            img = img.resize((max(1, round(img.width * factor)), max(1, round(img.height * factor))))
            pixels = list(img.get_flattened_data())
    except Exception:
        return []
    return palette_from_pixels(pixels, max_colors=max_colors)


def attach_issue_evidence(
    issues: list[dict[str, Any]],
    screenshot_path: Path,
    out_dir: Path,
    bookmark_id: str,
    run_id: str,
    viewport_name: str,
    device_scale_factor: int,
) -> None:
    """Create small visual evidence crops for the highest-priority findings.

    Sets ``evidence_url`` on each issue that got a crop. Issues are sorted by
    severity in the page, so the first ones are the most important.
    """
    try:
        source = Image.open(screenshot_path).convert("RGB")
    except Exception:
        return

    evidence_dir = out_dir / "evidence"
    evidence_dir.mkdir(exist_ok=True)
    try:
        for index, issue in enumerate(issues[:MAX_EVIDENCE_CROPS]):
            width = max(1, int(issue.get("width") or 1))
            height = max(1, int(issue.get("height") or 1))
            x = int(issue.get("x") or 0)
            y = int(issue.get("y") or 0)
            scale = max(1, device_scale_factor)
            padding = EVIDENCE_PADDING_CSS_PX * scale
            left = max(0, x * scale - padding)
            top = max(0, y * scale - padding)
            right = min(source.width, (x + width) * scale + padding)
            bottom = min(source.height, (y + height) * scale + padding)
            if right <= left or bottom <= top:
                continue
            crop = source.crop((left, top, right, bottom))
            crop.thumbnail(EVIDENCE_THUMBNAIL_SIZE)
            filename = f"{viewport_name}-{index + 1}.jpg"
            crop.save(evidence_dir / filename, "JPEG", quality=84, optimize=True)
            issue["evidence_url"] = run_file_url(bookmark_id, run_id, f"evidence/{filename}")
    finally:
        source.close()
