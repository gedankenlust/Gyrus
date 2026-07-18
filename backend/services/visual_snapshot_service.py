import json
import logging
import shutil
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable
from uuid import uuid4

from PIL import Image

from database import DATA_DIR
from services.outbound_url_security import (
    explicit_private_hostname,
    validate_outbound_url,
)

logger = logging.getLogger(__name__)


SNAPSHOT_DIR = DATA_DIR / "visual_snapshots"
SNAPSHOT_SCHEMA_VERSION = 2
MAX_SNAPSHOT_RUNS = 8
VIEWPORTS = [
    {"name": "desktop", "width": 1440, "height": 900, "device_scale_factor": 1},
    {"name": "tablet", "width": 834, "height": 1112, "device_scale_factor": 2},
    {"name": "mobile", "width": 390, "height": 844, "device_scale_factor": 2},
]


class VisualSnapshotUnavailable(Exception):
    """Raised when the optional browser runtime needed for snapshots is absent."""


def _bookmark_dir(bookmark_id: str) -> Path:
    return SNAPSHOT_DIR / bookmark_id


def snapshot_path(bookmark_id: str) -> Path:
    return _bookmark_dir(bookmark_id) / "visual_snapshot.json"


def _runs_dir(bookmark_id: str) -> Path:
    return _bookmark_dir(bookmark_id) / "runs"


def _run_dir(bookmark_id: str, run_id: str) -> Path:
    return _runs_dir(bookmark_id) / Path(run_id).name


def new_snapshot_run_id() -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    return f"{stamp}-{uuid4().hex[:8]}"


def read_snapshot(bookmark_id: str) -> dict[str, Any] | None:
    path = snapshot_path(bookmark_id)
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def read_snapshot_run(bookmark_id: str, run_id: str) -> dict[str, Any] | None:
    path = _run_dir(bookmark_id, run_id) / "snapshot.json"
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def list_snapshot_runs(bookmark_id: str) -> list[dict[str, Any]]:
    runs: list[dict[str, Any]] = []
    root = _runs_dir(bookmark_id)
    if not root.exists():
        return runs
    for path in sorted(root.iterdir(), reverse=True):
        if not path.is_dir():
            continue
        snapshot = read_snapshot_run(bookmark_id, path.name)
        if not snapshot:
            continue
        runs.append(
            {
                "run_id": snapshot.get("run_id", path.name),
                "captured_at": snapshot.get("captured_at"),
                "status": snapshot.get("status", "completed"),
                "viewport_count": len(snapshot.get("viewports", [])),
                "issue_count": sum(
                    len(viewport.get("responsive_issues") or [])
                    for viewport in snapshot.get("viewports", [])
                ),
            }
        )
    return runs


def snapshot_summary(bookmark_id: str) -> tuple[datetime | None, bool]:
    """Return capture time and whether all current viewport presets exist."""
    snapshot = read_snapshot(bookmark_id)
    if not snapshot:
        return None, False

    expected = {(item["name"], item["width"], item["height"]) for item in VIEWPORTS}
    actual = {
        (item.get("name"), item.get("width"), item.get("height"))
        for item in snapshot.get("viewports", [])
    }
    captured_at = None
    try:
        captured_at = datetime.fromisoformat(
            str(snapshot.get("captured_at", "")).replace("Z", "+00:00")
        )
    except ValueError:
        pass
    return captured_at, expected.issubset(actual)


async def capture_snapshot(
    bookmark_id: str,
    url: str,
    title: str = "",
    *,
    run_id: str | None = None,
    on_progress: Callable[[str, int, int], None] | None = None,
) -> dict[str, Any]:
    try:
        from playwright.async_api import async_playwright
    except Exception as e:
        raise VisualSnapshotUnavailable(
            "The design engine is unavailable in this build. Reinstall or update "
            "Gyrus and try again."
        ) from e

    run_id = run_id or new_snapshot_run_id()
    allowed_private_host = explicit_private_hostname(url)
    await validate_outbound_url(url, allowed_private_host=allowed_private_host)
    dns_cache: dict[tuple[str, int], tuple[str, ...]] = {}
    out_dir = _run_dir(bookmark_id, run_id)
    out_dir.mkdir(parents=True, exist_ok=True)

    snapshot: dict[str, Any] = {
        "bookmark_id": bookmark_id,
        "schema_version": SNAPSHOT_SCHEMA_VERSION,
        "run_id": run_id,
        "url": url,
        "title": title,
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "status": "running",
        "viewports": [],
        "errors": [],
    }

    if on_progress:
        on_progress("launching", 0, len(VIEWPORTS))

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        try:
            for index, viewport in enumerate(VIEWPORTS):
                context = None
                page = None
                try:
                    if on_progress:
                        on_progress(viewport["name"], index, len(VIEWPORTS))
                    context = await browser.new_context(
                        viewport={"width": viewport["width"], "height": viewport["height"]},
                        device_scale_factor=viewport["device_scale_factor"],
                        is_mobile=viewport["name"] in {"tablet", "mobile"},
                        has_touch=viewport["name"] in {"tablet", "mobile"},
                        accept_downloads=False,
                        service_workers="block",
                        permissions=[],
                    )

                    async def guard_route(route):
                        request_url = route.request.url
                        if request_url.startswith(("data:", "blob:", "about:")):
                            await route.continue_()
                            return
                        try:
                            await validate_outbound_url(
                                request_url,
                                allowed_private_host=allowed_private_host,
                                dns_cache=dns_cache,
                            )
                        except ValueError:
                            await route.abort("blockedbyclient")
                            return
                        await route.continue_()

                    await context.route("**/*", guard_route)
                    page = await context.new_page()
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
                    async def dismiss_dialog(dialog):
                        await dialog.dismiss()

                    async def close_popup(popup):
                        await popup.close()

                    page.on("dialog", dismiss_dialog)
                    page.on("popup", close_popup)

                    await page.goto(url, wait_until="domcontentloaded", timeout=30_000)
                    try:
                        await page.wait_for_load_state("networkidle", timeout=5_000)
                    except Exception as exc:
                        logger.debug("Viewport did not reach network idle: %s", exc)

                    screenshot_name = f"{viewport['name']}.png"
                    screenshot_path = out_dir / screenshot_name
                    await page.screenshot(path=str(screenshot_path), full_page=True)

                    data = await page.evaluate(
                        _VISUAL_EXTRACTOR_JS,
                        {
                            "is_touch": viewport["name"] in {"tablet", "mobile"},
                            "expected_width": viewport["width"],
                        },
                    )
                    issues = data.get("responsive_issues") or []
                    _attach_issue_evidence(
                        issues,
                        screenshot_path,
                        out_dir,
                        bookmark_id,
                        run_id,
                        viewport["name"],
                        viewport["device_scale_factor"],
                    )
                    data.update(
                        {
                            "name": viewport["name"],
                            "width": viewport["width"],
                            "height": viewport["height"],
                            "screenshot": screenshot_name,
                            "screenshot_url": (
                                f"/api/files/visual-snapshots/{bookmark_id}/runs/"
                                f"{run_id}/{screenshot_name}"
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
                    if context is not None:
                        await context.close()
                    elif page is not None:
                        await page.close()
        finally:
            await browser.close()

    snapshot["status"] = (
        "failed" if not snapshot["viewports"] else "partial" if snapshot["errors"] else "completed"
    )
    run_snapshot_path = out_dir / "snapshot.json"
    encoded = json.dumps(snapshot, ensure_ascii=False, indent=2)
    run_snapshot_path.write_text(encoded, encoding="utf-8")
    snapshot_path(bookmark_id).parent.mkdir(parents=True, exist_ok=True)
    snapshot_path(bookmark_id).write_text(
        encoded,
        encoding="utf-8",
    )
    _prune_snapshot_runs(bookmark_id)
    if on_progress:
        on_progress("finished", len(VIEWPORTS), len(VIEWPORTS))
    return snapshot


def _prune_snapshot_runs(bookmark_id: str, keep: int = MAX_SNAPSHOT_RUNS) -> None:
    root = _runs_dir(bookmark_id)
    if not root.exists():
        return
    runs = sorted((path for path in root.iterdir() if path.is_dir()), reverse=True)
    for stale in runs[max(1, keep):]:
        shutil.rmtree(stale, ignore_errors=True)


def discard_snapshot_run(bookmark_id: str, run_id: str) -> None:
    shutil.rmtree(_run_dir(bookmark_id, run_id), ignore_errors=True)


def _attach_issue_evidence(
    issues: list[dict[str, Any]],
    screenshot_path: Path,
    out_dir: Path,
    bookmark_id: str,
    run_id: str,
    viewport_name: str,
    device_scale_factor: int,
) -> None:
    """Create small visual evidence crops for the highest-priority findings."""
    try:
        source = Image.open(screenshot_path).convert("RGB")
    except Exception:
        return

    evidence_dir = out_dir / "evidence"
    evidence_dir.mkdir(exist_ok=True)
    try:
        for index, issue in enumerate(issues[:16]):
            width = max(1, int(issue.get("width") or 1))
            height = max(1, int(issue.get("height") or 1))
            x = int(issue.get("x") or 0)
            y = int(issue.get("y") or 0)
            scale = max(1, device_scale_factor)
            padding = 24 * scale
            left = max(0, x * scale - padding)
            top = max(0, y * scale - padding)
            right = min(source.width, (x + width) * scale + padding)
            bottom = min(source.height, (y + height) * scale + padding)
            if right <= left or bottom <= top:
                continue
            crop = source.crop((left, top, right, bottom))
            crop.thumbnail((720, 420))
            filename = f"{viewport_name}-{index + 1}.jpg"
            crop.save(evidence_dir / filename, "JPEG", quality=84, optimize=True)
            issue["evidence_url"] = (
                f"/api/files/visual-snapshots/{bookmark_id}/runs/{run_id}/"
                f"evidence/{filename}"
            )
    finally:
        source.close()


def _dominant_colors(path: Path, max_colors: int = 8) -> list[str]:
    try:
        with Image.open(path) as img:
            img = img.convert("RGB")
            img.thumbnail((240, 240))
            pixels = list(img.get_flattened_data())
    except Exception:
        return []

    # Bucket to 16-level RGB steps so tiny anti-aliased differences collapse.
    def bucket(pixel: tuple[int, int, int]) -> tuple[int, int, int]:
        return tuple(round(channel / 16) * 16 for channel in pixel)

    counts = Counter(bucket(pixel) for pixel in pixels)
    colors: list[str] = []
    neutral_fallbacks: list[str] = []
    for (r, g, b), _ in counts.most_common(30):
        value = f"#{max(0, min(r, 255)):02x}{max(0, min(g, 255)):02x}{max(0, min(b, 255)):02x}"
        is_neutral = max(r, g, b) - min(r, g, b) <= 10
        is_page_chrome = is_neutral and (max(r, g, b) >= 240 or max(r, g, b) <= 24)
        if is_page_chrome:
            neutral_fallbacks.append(value)
        elif len(colors) < max_colors:
            colors.append(value)

    # Keep one surface neutral when a page is monochrome, without letting
    # white or black backgrounds drown out the useful palette.
    if len(colors) < max_colors and neutral_fallbacks:
        colors.append(neutral_fallbacks[0])
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
(inspection) => {
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

  const responsiveIssues = [];
  const issueKeys = new Set();
  const severityOrder = {high: 0, medium: 1, low: 2};

  function addIssue(kind, severity, title, detail, el, metric = '') {
    const rect = el?.getBoundingClientRect?.() || {left: 0, top: 0, width: innerWidth, height: 1};
    const selector = el ? selectorHint(el) : 'html';
    const key = `${kind}:${selector}:${Math.round(rect.left)}:${Math.round(rect.top)}`;
    if (issueKeys.has(key) || responsiveIssues.length >= 60) return;
    issueKeys.add(key);
    responsiveIssues.push({
      id: key,
      kind,
      severity,
      title,
      detail,
      selector_hint: selector,
      text: el ? textOf(el) : '',
      x: Math.max(0, Math.round(rect.left + scrollX)),
      y: Math.max(0, Math.round(rect.top + scrollY)),
      width: Math.max(1, Math.round(rect.width)),
      height: Math.max(1, Math.round(rect.height)),
      metric,
    });
  }

  const documentWidth = Math.max(
    document.documentElement.scrollWidth,
    document.body?.scrollWidth || 0
  );
  const viewportMeta = document.querySelector('meta[name="viewport"]');
  if (inspection?.is_touch && !viewportMeta) {
    addIssue(
      'missing_viewport_meta',
      'high',
      'Mobile viewport configuration is missing',
      'Without a viewport meta tag, mobile browsers may render the page at a desktop-like width.',
      document.documentElement,
      'meta[name="viewport"] not found'
    );
  }
  if (documentWidth > innerWidth + 2) {
    addIssue(
      'horizontal_overflow',
      'high',
      'Page overflows horizontally',
      `The rendered page is ${documentWidth - innerWidth}px wider than this viewport.`,
      document.documentElement,
      `${documentWidth}px document / ${innerWidth}px viewport`
    );
  }

  const visibleElements = Array.from(document.body?.querySelectorAll('*') || [])
    .slice(0, 2500)
    .filter((el) => {
      const rect = el.getBoundingClientRect();
      const style = getComputedStyle(el);
      return rect.width > 1 && rect.height > 1 && style.display !== 'none' &&
        style.visibility !== 'hidden' && Number(style.opacity || 1) > 0;
    });

  for (const el of visibleElements) {
    const rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    const text = textOf(el);

    if (rect.right > innerWidth + 3 || rect.left < -3) {
      const outside = Math.max(rect.right - innerWidth, -rect.left);
      if (outside >= 4 && rect.width < documentWidth * 0.98) {
        addIssue(
          'offscreen_element',
          outside > 40 ? 'high' : 'medium',
          'Element extends beyond the viewport',
          `This element is approximately ${Math.round(outside)}px outside the visible width.`,
          el,
          `${Math.round(rect.width)}x${Math.round(rect.height)}px`
        );
      }
    }

    const clipsX = el.scrollWidth > el.clientWidth + 3 && ['hidden', 'clip'].includes(style.overflowX);
    const clipsY = el.scrollHeight > el.clientHeight + 3 && ['hidden', 'clip'].includes(style.overflowY);
    if (text && (clipsX || clipsY)) {
      addIssue(
        'clipped_content',
        'medium',
        'Content may be clipped',
        'The content is larger than its box while overflow is hidden.',
        el,
        `${el.scrollWidth}x${el.scrollHeight}px content / ${el.clientWidth}x${el.clientHeight}px box`
      );
    }

    const fontSize = parseFloat(style.fontSize || '0');
    if (text && fontSize > 0 && fontSize < 12 && rect.width >= 12 && rect.height >= 6) {
      addIssue(
        'small_text',
        fontSize < 10 ? 'medium' : 'low',
        'Very small text',
        'This text may be difficult to read at the selected viewport.',
        el,
        `${fontSize}px`
      );
    }

    const isInteractive = el.matches('a[href],button,input,select,textarea,[role="button"],[tabindex]:not([tabindex="-1"])');
    if (innerWidth <= 900 && isInteractive && (rect.width < 44 || rect.height < 44)) {
      addIssue(
        'small_touch_target',
        rect.width < 28 || rect.height < 28 ? 'medium' : 'low',
        'Small touch target',
        'This control is smaller than the recommended 44x44px touch area.',
        el,
        `${Math.round(rect.width)}x${Math.round(rect.height)}px`
      );
    }

    if (['fixed', 'sticky'].includes(style.position) && rect.height > innerHeight * 0.3) {
      addIssue(
        'large_sticky_element',
        'medium',
        'Sticky element covers much of the viewport',
        'This fixed or sticky element occupies more than 30% of the viewport height.',
        el,
        `${Math.round((rect.height / innerHeight) * 100)}% of viewport height`
      );
    }
  }

  const interactiveElements = visibleElements
    .filter((el) => el.matches('a[href],button,input,select,textarea,[role="button"]'))
    .slice(0, 160);
  for (let i = 0; i < interactiveElements.length; i += 1) {
    const first = interactiveElements[i];
    const a = first.getBoundingClientRect();
    for (let j = i + 1; j < interactiveElements.length; j += 1) {
      const second = interactiveElements[j];
      if (first.contains(second) || second.contains(first)) continue;
      const b = second.getBoundingClientRect();
      const overlapWidth = Math.max(0, Math.min(a.right, b.right) - Math.max(a.left, b.left));
      const overlapHeight = Math.max(0, Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top));
      const overlapArea = overlapWidth * overlapHeight;
      const smallerArea = Math.max(1, Math.min(a.width * a.height, b.width * b.height));
      if (overlapArea / smallerArea >= 0.2) {
        addIssue(
          'overlapping_controls',
          'high',
          'Interactive controls overlap',
          `This control overlaps another interactive element (${selectorHint(second)}).`,
          first,
          `${Math.round((overlapArea / smallerArea) * 100)}% overlap`
        );
      }
    }
  }

  responsiveIssues.sort((a, b) =>
    (severityOrder[a.severity] ?? 9) - (severityOrder[b.severity] ?? 9)
  );

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
    responsive_issues: responsiveIssues.slice(0, 40),
  };
}
"""
