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
    {"name": "tablet", "width": 834, "height": 1112, "device_scale_factor": 2},
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
        "errors": [],
    }

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        try:
            for viewport in VIEWPORTS:
                page = None
                try:
                    page = await browser.new_page(
                        viewport={"width": viewport["width"], "height": viewport["height"]},
                        device_scale_factor=viewport["device_scale_factor"],
                        is_mobile=viewport["name"] in {"tablet", "mobile"},
                    )
                    network_entries: dict[str, dict[str, Any]] = {}
                    console_messages: list[dict[str, Any]] = []

                    def on_request(request):
                        network_entries[request.url] = {
                            "url": request.url,
                            "method": request.method,
                            "resource_type": request.resource_type,
                            "status": None,
                            "failed": False,
                            "failure": None,
                        }

                    def on_response(response):
                        entry = network_entries.setdefault(response.url, {"url": response.url})
                        entry.update(
                            {
                                "status": response.status,
                                "resource_type": response.request.resource_type,
                                "method": response.request.method,
                                "failed": response.status >= 400,
                                "content_type": response.headers.get("content-type", ""),
                                "content_length": response.headers.get("content-length", ""),
                            }
                        )

                    def on_request_failed(request):
                        entry = network_entries.setdefault(request.url, {"url": request.url})
                        failure = request.failure or ""
                        entry.update(
                            {
                                "method": request.method,
                                "resource_type": request.resource_type,
                                "failed": True,
                                "failure": failure,
                            }
                        )

                    def on_console(message):
                        console_messages.append(
                            {
                                "type": message.type,
                                "text": message.text[:1000],
                                "location": message.location,
                            }
                        )

                    page.on("request", on_request)
                    page.on("response", on_response)
                    page.on("requestfailed", on_request_failed)
                    page.on("console", on_console)

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
                            "network": _network_summary(network_entries),
                            "console_messages": console_messages[:60],
                        }
                    )
                    snapshot["viewports"].append(data)
                except Exception as e:
                    snapshot["errors"].append(
                        {
                            "viewport": viewport["name"],
                            "message": str(e)[:1000],
                        }
                    )
                finally:
                    if page is not None:
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


def _network_summary(entries: dict[str, dict[str, Any]]) -> dict[str, Any]:
    resources = list(entries.values())
    counts: Counter[str] = Counter()
    failed: list[dict[str, Any]] = []
    large: list[dict[str, Any]] = []

    for item in resources:
        resource_type = item.get("resource_type") or "other"
        counts[resource_type] += 1

        if item.get("failed") or (item.get("status") and item["status"] >= 400):
            failed.append(_network_item(item))

        try:
            size = int(item.get("content_length") or 0)
        except Exception:
            size = 0
        if size >= 250_000:
            large_item = _network_item(item)
            large_item["content_length"] = size
            large.append(large_item)

    return {
        "request_count": len(resources),
        "resource_counts": [
            {"type": kind, "count": count}
            for kind, count in sorted(counts.items(), key=lambda pair: (-pair[1], pair[0]))
        ],
        "failed_requests": failed[:30],
        "large_requests": sorted(large, key=lambda item: item.get("content_length", 0), reverse=True)[:30],
    }


def _network_item(item: dict[str, Any]) -> dict[str, Any]:
    return {
        "url": item.get("url", ""),
        "method": item.get("method", ""),
        "resource_type": item.get("resource_type", ""),
        "status": item.get("status"),
        "content_type": item.get("content_type", ""),
        "failure": item.get("failure", ""),
    }


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
    if (!el) return '';
    return (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 160);
  }

  function attr(el, name) {
    if (!el) return '';
    return el.getAttribute(name) || '';
  }

  function absoluteUrl(value) {
    try { return value ? new URL(value, location.href).href : ''; } catch (_) { return value || ''; }
  }

  function metaBy(selector) {
    return document.querySelector(selector)?.content || '';
  }

  function allMeta(prefix) {
    return Array.from(document.querySelectorAll(`meta[${prefix}]`)).map((el) => ({
      name: attr(el, prefix),
      content: attr(el, 'content')
    })).filter((item) => item.name || item.content).slice(0, 80);
  }

  function selectorHint(el) {
    if (el.id) return `#${el.id}`;
    if (el.className && typeof el.className === 'string') {
      return '.' + el.className.trim().split(/\s+/).slice(0, 3).join('.');
    }
    return el.tagName.toLowerCase();
  }

  function styleOf(el) {
    const s = window.getComputedStyle(el);
    const rect = el.getBoundingClientRect();
    return {
      tag: el.tagName.toLowerCase(),
      selector_hint: selectorHint(el),
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

  const rootStyles = window.getComputedStyle(document.documentElement);
  const cssVariables = [];
  for (const name of rootStyles) {
    if (name.startsWith('--')) {
      cssVariables.push({name, value: rootStyles.getPropertyValue(name).trim()});
    }
  }

  const imgAssets = Array.from(document.images).map((img) => ({
    kind: 'image',
    url: img.currentSrc || img.src || '',
    alt: attr(img, 'alt'),
    width: img.naturalWidth || img.width || 0,
    height: img.naturalHeight || img.height || 0,
    loading: attr(img, 'loading'),
    selector_hint: selectorHint(img),
  })).filter((item) => item.url).slice(0, 120);

  const iconAssets = Array.from(document.querySelectorAll('link[rel*="icon" i], link[rel*="apple-touch-icon" i]')).map((el) => ({
    kind: 'icon',
    url: absoluteUrl(attr(el, 'href')),
    rel: attr(el, 'rel'),
    sizes: attr(el, 'sizes'),
    type: attr(el, 'type')
  })).filter((item) => item.url).slice(0, 40);

  const styleAssets = Array.from(document.querySelectorAll('link[rel="stylesheet"]')).map((el) => ({
    kind: 'stylesheet',
    url: absoluteUrl(attr(el, 'href')),
    media: attr(el, 'media')
  })).filter((item) => item.url).slice(0, 80);

  const scriptAssets = Array.from(document.scripts).map((el) => ({
    kind: 'script',
    url: absoluteUrl(attr(el, 'src')),
    async: el.async,
    defer: el.defer,
    type: attr(el, 'type')
  })).filter((item) => item.url).slice(0, 80);

  const links = Array.from(document.querySelectorAll('a[href]')).map((a) => {
    const href = absoluteUrl(attr(a, 'href'));
    let isExternal = false;
    try { isExternal = new URL(href).origin !== location.origin; } catch (_) {}
    return {url: href, text: textOf(a), external: isExternal};
  }).filter((item) => item.url);

  const headings = Array.from(document.querySelectorAll('h1,h2,h3,h4,h5,h6')).map((heading) => ({
    level: Number(heading.tagName.slice(1)),
    text: textOf(heading),
  })).filter((item) => item.text).slice(0, 120);

  const missingAltImages = imgAssets.filter((img) => !img.alt).slice(0, 80);
  const emptyButtons = Array.from(document.querySelectorAll('button, [role="button"]')).map((button) => ({
    selector_hint: selectorHint(button),
    text: textOf(button),
    aria_label: attr(button, 'aria-label')
  })).filter((button) => !button.text && !button.aria_label).slice(0, 80);

  const unlabeledInputs = Array.from(document.querySelectorAll('input, textarea, select')).map((input) => {
    const id = attr(input, 'id');
    const label = id ? document.querySelector(`label[for="${CSS.escape(id)}"]`) : null;
    const wrappedLabel = input.closest('label');
    return {
      selector_hint: selectorHint(input),
      type: attr(input, 'type') || input.tagName.toLowerCase(),
      name: attr(input, 'name'),
      placeholder: attr(input, 'placeholder'),
      label: textOf(label || wrappedLabel),
      aria_label: attr(input, 'aria-label'),
    };
  }).filter((input) => !input.label && !input.aria_label).slice(0, 80);

  const headingSkips = [];
  for (let i = 1; i < headings.length; i += 1) {
    if (headings[i].level - headings[i - 1].level > 1) {
      headingSkips.push({from: headings[i - 1], to: headings[i]});
    }
  }

  return {
    page_title: document.title || '',
    meta_description: document.querySelector('meta[name="description"]')?.content || document.querySelector('meta[property="og:description"]')?.content || '',
    seo: {
      title: document.title || '',
      meta_description: metaBy('meta[name="description"]') || metaBy('meta[property="og:description"]'),
      canonical: document.querySelector('link[rel="canonical"]')?.href || '',
      language: document.documentElement.lang || '',
      robots: metaBy('meta[name="robots"]'),
      open_graph: allMeta('property').filter((item) => item.name.startsWith('og:')),
      twitter: allMeta('name').filter((item) => item.name.startsWith('twitter:')),
      json_ld: Array.from(document.querySelectorAll('script[type="application/ld+json"]')).map((el) => (el.textContent || '').trim()).filter(Boolean).slice(0, 20),
      headings,
      internal_links: links.filter((link) => !link.external).length,
      external_links: links.filter((link) => link.external).length,
    },
    assets: {
      images: imgAssets,
      icons: iconAssets,
      stylesheets: styleAssets,
      scripts: scriptAssets,
    },
    accessibility: {
      missing_alt_images: missingAltImages,
      empty_buttons: emptyButtons,
      unlabeled_inputs: unlabeledInputs,
      heading_skips: headingSkips.slice(0, 40),
    },
    css_variables: cssVariables.slice(0, 160),
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
