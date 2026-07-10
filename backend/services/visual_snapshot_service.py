import json
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from PIL import Image

from database import DATA_DIR


SNAPSHOT_DIR = DATA_DIR / "visual_snapshots"
VIEWPORTS = [
    {"name": "desktop", "width": 1440, "height": 1200, "device_scale_factor": 1},
    {"name": "mobile", "width": 390, "height": 844, "device_scale_factor": 2},
]


class VisualSnapshotUnavailable(Exception):
    """Raised when the optional browser runtime needed for snapshots is absent."""


def _bookmark_dir(bookmark_id: str) -> Path:
    return SNAPSHOT_DIR / bookmark_id


def snapshot_path(bookmark_id: str) -> Path:
    return _bookmark_dir(bookmark_id) / "visual_snapshot.json"


def read_snapshot(bookmark_id: str) -> dict[str, Any] | None:
    path = snapshot_path(bookmark_id)
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


async def capture_snapshot(bookmark_id: str, url: str, title: str = "") -> dict[str, Any]:
    try:
        from playwright.async_api import async_playwright
    except Exception as e:
        raise VisualSnapshotUnavailable(
            "Visual snapshots need Playwright. Install it in the bundled backend "
            "runtime before using Design Brain capture."
        ) from e

    out_dir = _bookmark_dir(bookmark_id)
    out_dir.mkdir(parents=True, exist_ok=True)

    snapshot: dict[str, Any] = {
        "bookmark_id": bookmark_id,
        "url": url,
        "title": title,
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "viewports": [],
    }

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        try:
            for viewport in VIEWPORTS:
                page = await browser.new_page(
                    viewport={"width": viewport["width"], "height": viewport["height"]},
                    device_scale_factor=viewport["device_scale_factor"],
                    is_mobile=viewport["name"] == "mobile",
                )
                await page.goto(url, wait_until="domcontentloaded", timeout=30_000)
                try:
                    await page.wait_for_load_state("networkidle", timeout=5_000)
                except Exception:
                    pass

                screenshot_name = f"{viewport['name']}.png"
                screenshot_path = out_dir / screenshot_name
                await page.screenshot(path=str(screenshot_path), full_page=True)

                data = await page.evaluate(_VISUAL_EXTRACTOR_JS)
                data.update(
                    {
                        "name": viewport["name"],
                        "width": viewport["width"],
                        "height": viewport["height"],
                        "screenshot": screenshot_name,
                        "screenshot_url": (
                            f"/api/files/visual-snapshots/{bookmark_id}/{screenshot_name}"
                        ),
                        "dominant_colors": _dominant_colors(screenshot_path),
                    }
                )
                snapshot["viewports"].append(data)
                await page.close()
        finally:
            await browser.close()

    snapshot_path(bookmark_id).write_text(
        json.dumps(snapshot, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return snapshot


def _dominant_colors(path: Path, max_colors: int = 8) -> list[str]:
    try:
        with Image.open(path) as img:
            img = img.convert("RGB")
            img.thumbnail((240, 240))
            pixels = list(img.getdata())
    except Exception:
        return []

    # Bucket to 16-level RGB steps so tiny anti-aliased differences collapse.
    def bucket(pixel: tuple[int, int, int]) -> tuple[int, int, int]:
        return tuple(round(channel / 16) * 16 for channel in pixel)

    counts = Counter(bucket(pixel) for pixel in pixels)
    colors: list[str] = []
    for (r, g, b), _ in counts.most_common(30):
        # Skip near-white/near-black page chrome dominance unless the palette
        # would otherwise be empty.
        if len(colors) < max_colors:
            colors.append(f"#{max(0, min(r, 255)):02x}{max(0, min(g, 255)):02x}{max(0, min(b, 255)):02x}")
    return colors[:max_colors]


_VISUAL_EXTRACTOR_JS = r"""
() => {
  const selectors = [
    'body', 'header', 'nav', 'main', 'section', 'article',
    'h1', 'h2', 'h3', 'p', 'a', 'button',
    '[class*="hero" i]', '[class*="card" i]', '[class*="btn" i]',
    '[class*="cta" i]', '[role="button"]'
  ];
  const seen = new Set();
  const samples = [];

  function textOf(el) {
    return (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 160);
  }

  function styleOf(el) {
    const s = window.getComputedStyle(el);
    const rect = el.getBoundingClientRect();
    return {
      tag: el.tagName.toLowerCase(),
      selector_hint: el.id ? `#${el.id}` : (el.className && typeof el.className === 'string' ? '.' + el.className.trim().split(/\s+/).slice(0, 3).join('.') : el.tagName.toLowerCase()),
      text: textOf(el),
      x: Math.round(rect.x),
      y: Math.round(rect.y),
      width: Math.round(rect.width),
      height: Math.round(rect.height),
      display: s.display,
      position: s.position,
      font_family: s.fontFamily,
      font_size: s.fontSize,
      font_weight: s.fontWeight,
      line_height: s.lineHeight,
      color: s.color,
      background_color: s.backgroundColor,
      border_radius: s.borderRadius,
      box_shadow: s.boxShadow,
      letter_spacing: s.letterSpacing,
      text_transform: s.textTransform,
      margin: `${s.marginTop} ${s.marginRight} ${s.marginBottom} ${s.marginLeft}`,
      padding: `${s.paddingTop} ${s.paddingRight} ${s.paddingBottom} ${s.paddingLeft}`,
    };
  }

  for (const selector of selectors) {
    for (const el of Array.from(document.querySelectorAll(selector)).slice(0, 24)) {
      if (seen.has(el) || samples.length >= 90) continue;
      const rect = el.getBoundingClientRect();
      if (rect.width < 8 || rect.height < 8) continue;
      seen.add(el);
      samples.push(styleOf(el));
    }
  }

  const colorSet = new Set();
  const fontSet = new Set();
  for (const item of samples) {
    if (item.color && item.color !== 'rgba(0, 0, 0, 0)') colorSet.add(item.color);
    if (item.background_color && item.background_color !== 'rgba(0, 0, 0, 0)') colorSet.add(item.background_color);
    if (item.font_family) fontSet.add(item.font_family);
  }

  return {
    page_title: document.title || '',
    meta_description: document.querySelector('meta[name="description"]')?.content || document.querySelector('meta[property="og:description"]')?.content || '',
    structure: {
      h1: Array.from(document.querySelectorAll('h1')).map(textOf).filter(Boolean).slice(0, 8),
      h2: Array.from(document.querySelectorAll('h2')).map(textOf).filter(Boolean).slice(0, 16),
      links: document.querySelectorAll('a').length,
      buttons: document.querySelectorAll('button, [role="button"]').length,
      images: document.querySelectorAll('img').length,
      svgs: document.querySelectorAll('svg').length,
      forms: document.querySelectorAll('form').length,
    },
    observed_colors: Array.from(colorSet).slice(0, 32),
    observed_fonts: Array.from(fontSet).slice(0, 16),
    element_samples: samples,
  };
}
"""
