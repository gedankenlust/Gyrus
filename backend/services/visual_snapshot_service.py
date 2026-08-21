import asyncio
import json
import logging
import re
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
# 6: Website inspection includes rendered navigation trees and a sitemap-backed
#    page hierarchy. Keep in sync with
#    expectedSnapshotSchemaVersion in
#    Gyrus/Views/PreviewPanel/VisualSnapshotTabView.swift — the app compares the
#    two and offers a reinspect when a stored snapshot predates the current
#    capture.
SNAPSHOT_SCHEMA_VERSION = 6
MAX_SNAPSHOT_RUNS = 8
MAX_TECHNOLOGY_SCRIPT_PROBES = 12
MAX_TECHNOLOGY_SCRIPT_BYTES = 2_000_000
VIEWPORTS = [
    {"name": "desktop", "width": 1440, "height": 900, "device_scale_factor": 1},
    {"name": "tablet", "width": 834, "height": 1112, "device_scale_factor": 2},
    {"name": "mobile", "width": 390, "height": 844, "device_scale_factor": 2},
]
DESIGN_INSPECTION_STEPS = len(VIEWPORTS) + 1


_TECHNOLOGY_RULES = (
    ("WordPress", "CMS", ("wp-content", "wp-includes", "wp-json")),
    ("WooCommerce", "E-Commerce", ("woocommerce", "wc-blocks")),
    ("Shopify", "E-Commerce", ("shopify", "myshopify", "cdn.shopify.com")),
    ("Webflow", "Website Builder", ("webflow.js", "webflow.io", "data-wf-page", "data-wf-site")),
    ("Framer", "Website Builder", ("framerusercontent", "framer.com/m/")),
    ("Wix", "Website Builder", ("wix.com", "wixstatic", "parastorage", "wix-code")),
    ("Squarespace", "Website Builder", ("static1.squarespace", "assets.squarespace")),
    ("STRATO", "Hosting / Builder", ("strato", "strato-editor", "websites-editor")),
    ("Drupal", "CMS", ("drupalsettings", "sites/default/files", "/core/misc/drupal")),
    ("TYPO3", "CMS", ("typo3", "typo3temp", "typo3conf")),
    ("Ghost", "CMS", ("ghost.io", "ghost.org", "/ghost/")),
    ("Next.js", "Framework", ("__next_data__", "/_next/")),
    ("Nuxt", "Framework", ("__nuxt__", "/_nuxt/")),
    ("Astro", "Framework", ("astro-island", "/_astro/")),
    ("Gatsby", "Framework", ("___gatsby", "/page-data/")),
    ("SvelteKit", "Framework", ("/_app/immutable/", "data-sveltekit")),
    ("Angular", "Framework", ("@angular/", "angular.min.js", "ng-version")),
    ("Vue", "Framework", ("vue.runtime", "vue.global", "vue.min.js", "data-v-app")),
    ("TanStack Start", "Framework", ("tanstack-start", "tsr-stream-barrier")),
    ("TanStack Router", "Router", ("tanstack-router", "data-route-announcer", "router-compat")),
    ("React", "UI Library", ("react-dom", "react.production", "__reactfiber", "__reactcontainer")),
    ("Vite", "Build Tool", ("vite-build-assets", "/@vite/", "vite/client")),
    ("Tailwind CSS", "CSS Framework", ("tailwind", "--tw-")),
    ("Bootstrap", "CSS Framework", ("bootstrap",)),
    ("Radix UI", "Component Library", ("data-radix", "radix-ui")),
    ("Lucide", "Icon Library", ("lucide", "createLucideIcon")),
    ("Motion", "Animation Library", ("/motion-", "motion/react", "framer-motion")),
    ("Plausible", "Analytics", ("plausible.js", "plausible.io")),
    ("SSR + Hydration", "Rendering", ("ssr-hydration",)),
    ("PWA Manifest", "PWA", ("web-app-manifest",)),
    ("Apache", "Web Server", ("apache",)),
    ("Plesk", "Server Management", ("plesk", "plesklin")),
)


_SCRIPT_CONTENT_FINGERPRINTS = (
    ("TanStack Start", ("$tsr-stream-barrier", "tanstack-start", "createserverfn")),
    ("TanStack Router", ("data-route-announcer", "router-compat", "@tanstack/router")),
    ("Vite", ("__vite__mapdeps", "vite/modulepreload-polyfill")),
    ("Radix UI", ("data-radix-collection-item", "radix-ui", "radix-collection")),
    ("Lucide", ("createlucideicon", "lucide-react", "lucide-vue")),
    ("Motion", ("framer-motion", "motion/react", "motion-dom", "motionconfigcontext")),
    ("Plausible", ("/scripts/plausible.js", "plausible.io/js/")),
)


def _script_content_markers(content: bytes) -> list[str]:
    """Return known library fingerprints without retaining third-party code."""
    if not content or len(content) > MAX_TECHNOLOGY_SCRIPT_BYTES:
        return []

    lowered = content.decode("utf-8", errors="ignore").lower()
    return [
        name
        for name, needles in _SCRIPT_CONTENT_FINGERPRINTS
        if any(needle in lowered for needle in needles)
    ]


def _script_technology_versions(content: bytes) -> dict[str, str]:
    """Extract versions only from explicit package metadata in loaded scripts."""
    if not content or len(content) > MAX_TECHNOLOGY_SCRIPT_BYTES:
        return {}

    text = content.decode("utf-8", errors="ignore")
    react_match = re.search(
        r"version\s*:\s*[`\"']([0-9]+(?:\.[0-9]+){1,3}(?:[-+][0-9A-Za-z.-]+)?)"
        r"[`\"']\s*,\s*rendererPackageName\s*:\s*[`\"']react-dom[`\"']",
        text,
        flags=re.IGNORECASE,
    )
    return {"React": react_match.group(1)} if react_match else {}


def _is_primary_script_bundle(url: str) -> bool:
    """Keep the entry bundle eligible even when preload chunks fill the probe cap."""
    path = url.lower().split("?", 1)[0]
    return bool(
        re.search(
            r"/(?:index|main|app)-(?=[a-z0-9_-]{6,}\.m?js$)(?=[a-z0-9_-]*\d)"
            r"[a-z0-9_-]+\.m?js$",
            path,
        )
    )


def _detect_technologies(signals: dict[str, Any] | None) -> list[dict[str, Any]]:
    """Classify rendered-page signals without guessing beyond the evidence."""
    if not signals:
        return []

    generator = str(signals.get("generator") or "").strip()
    marker_names = {
        str(name).lower()
        for name in signals.get("runtime_markers") or []
        if str(name).strip()
    }
    script_content_marker_names = {
        str(name).lower()
        for name in signals.get("script_content_markers") or []
        if str(name).strip()
    }
    technology_versions = {
        str(name).lower(): str(version).strip()
        for name, version in (signals.get("technology_versions") or {}).items()
        if str(name).strip() and str(version).strip()
    }
    sources = [
        ("Generator", generator),
        *[("Script", str(value)) for value in signals.get("script_urls") or []],
        *[("Stylesheet", str(value)) for value in signals.get("stylesheet_urls") or []],
        *[("Markup", str(value)) for value in signals.get("markup_hints") or []],
        *[("Header", str(value)) for value in signals.get("response_headers") or []],
    ]

    technologies: list[dict[str, Any]] = []
    generator_was_classified = False
    for name, category, needles in _TECHNOLOGY_RULES:
        normalized_needles = tuple(needle.lower() for needle in needles)
        evidence: list[str] = []
        marker_match = name.lower() in marker_names
        content_marker_match = name.lower() in script_content_marker_names
        if marker_match:
            evidence.append(f"Runtime marker: {name}")
        if content_marker_match:
            evidence.append(f"Loaded JavaScript fingerprint: {name}")

        for source, value in sources:
            if not value:
                continue
            lowered = value.lower()
            matches = (
                name.lower() in lowered
                if source == "Generator"
                else any(needle in lowered for needle in normalized_needles)
            )
            if matches:
                evidence.append(f"{source}: {value[:180]}")
                if source == "Generator":
                    generator_was_classified = True
            if len(evidence) >= 3:
                break

        if evidence:
            technology = {
                "name": name,
                "category": category,
                "confidence": "high" if marker_match or content_marker_match or any(
                    item.startswith(("Generator:", "Header:")) for item in evidence
                ) else "medium",
                "evidence": evidence,
            }
            version = technology_versions.get(name.lower())
            if not version and generator:
                generator_version = re.search(
                    rf"\b{re.escape(name)}\s+v?([0-9]+(?:\.[0-9]+){{1,3}}(?:[-+][0-9A-Za-z.-]+)?)",
                    generator,
                    flags=re.IGNORECASE,
                )
                if generator_version:
                    version = generator_version.group(1)
            if version:
                technology["version"] = version
            technologies.append(technology)

    if generator and not generator_was_classified:
        technologies.append(
            {
                "name": generator[:80],
                "category": "Site Generator",
                "confidence": "high",
                "evidence": [f"Generator: {generator[:180]}"],
            }
        )

    return technologies


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
        "navigation": [],
        "site_structure": None,
        "viewports": [],
        "errors": [],
    }

    if on_progress:
        on_progress("launching", 0, DESIGN_INSPECTION_STEPS)

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        try:
            for index, viewport in enumerate(VIEWPORTS):
                context = None
                page = None
                try:
                    if on_progress:
                        on_progress(viewport["name"], index, DESIGN_INSPECTION_STEPS)
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
                    script_content_markers: set[str] = set()
                    technology_versions: dict[str, str] = {}
                    script_probe_tasks: list[asyncio.Task] = []

                    async def probe_script_response(response):
                        try:
                            headers = response.headers
                            content_type = headers.get("content-type", "").lower()
                            is_javascript = (
                                "javascript" in content_type
                                or response.url.lower().split("?", 1)[0].endswith((".js", ".mjs"))
                            )
                            if not is_javascript:
                                return

                            content_length = headers.get("content-length", "")
                            if content_length.isdigit() and int(content_length) > MAX_TECHNOLOGY_SCRIPT_BYTES:
                                return

                            content = await response.body()
                            script_content_markers.update(_script_content_markers(content))
                            technology_versions.update(_script_technology_versions(content))
                        except Exception as exc:
                            logger.debug("Could not inspect script fingerprint for %s: %s", response.url, exc)

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
                                "server": response.headers.get("server", ""),
                                "powered_by": response.headers.get("x-powered-by", ""),
                            }
                        )
                        content_type = response.headers.get("content-type", "").lower()
                        response_path = response.url.lower().split("?", 1)[0]
                        is_javascript = (
                            "javascript" in content_type
                            or response_path.endswith((".js", ".mjs"))
                        )
                        has_probe_capacity = len(script_probe_tasks) < MAX_TECHNOLOGY_SCRIPT_PROBES
                        if is_javascript and (has_probe_capacity or _is_primary_script_bundle(response.url)):
                            task = asyncio.create_task(probe_script_response(response))
                            script_probe_tasks.append(task)

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

                    if script_probe_tasks:
                        await asyncio.gather(*script_probe_tasks, return_exceptions=True)

                    rendered_navigation = []
                    if viewport["name"] == "desktop":
                        rendered_navigation = await _capture_rendered_navigation(page)

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
                    data.pop("navigation", None)
                    if rendered_navigation and not snapshot["navigation"]:
                        snapshot["navigation"] = rendered_navigation
                    technology_signals = data.pop("_technology_signals", None)
                    if technology_signals is not None:
                        technology_signals["script_content_markers"] = sorted(script_content_markers)
                        technology_signals["technology_versions"] = technology_versions
                        response_headers: list[str] = []
                        for entry in network_entries.values():
                            if entry.get("resource_type") != "document":
                                continue
                            if entry.get("server"):
                                response_headers.append(f"Server: {entry['server']}")
                            if entry.get("powered_by"):
                                response_headers.append(
                                    f"X-Powered-By: {entry['powered_by']}"
                                )
                        technology_signals["response_headers"] = list(
                            dict.fromkeys(response_headers)
                        )
                    data["technologies"] = _detect_technologies(technology_signals)
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

    if on_progress:
        on_progress("site_structure", len(VIEWPORTS), DESIGN_INSPECTION_STEPS)
    try:
        from services.site_structure_service import site_structure_service

        structure_data = await site_structure_service.data_for_url(
            bookmark_id,
            url,
            force_refresh=True,
        )
        snapshot["site_structure"] = site_structure_service.snapshot_payload(structure_data)
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        logger.warning("Could not map website structure for %s: %s", url, exc)
        snapshot["site_structure"] = {
            "origin": url,
            "listed_page_count": 0,
            "sitemap_page_count": 0,
            "crawled_page_count": 0,
            "pages": [],
            "page_tree": [],
            "sitemap_sources": [],
            "errors": [str(exc)[:1000]],
        }

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
        on_progress("finished", DESIGN_INSPECTION_STEPS, DESIGN_INSPECTION_STEPS)
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


def _merge_navigation_groups(
    target: list[dict[str, Any]],
    incoming: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    def merge_items(existing: list[dict[str, Any]], additions: list[dict[str, Any]]) -> None:
        by_key = {
            (item.get("url") or "", item.get("label") or ""): item
            for item in existing
        }
        for addition in additions:
            key = (addition.get("url") or "", addition.get("label") or "")
            item = by_key.get(key)
            if item is None:
                item = {
                    "label": addition.get("label") or addition.get("url") or "",
                    "url": addition.get("url") or "",
                    "children": [],
                }
                existing.append(item)
                by_key[key] = item
            merge_items(item["children"], addition.get("children") or [])

    groups = {group.get("label") or "Navigation": group for group in target}
    for addition in incoming:
        label = addition.get("label") or "Navigation"
        group = groups.get(label)
        if group is None:
            group = {"label": label, "items": []}
            target.append(group)
            groups[label] = group
        merge_items(group["items"], addition.get("items") or [])
    return target


async def _capture_rendered_navigation(page) -> list[dict[str, Any]]:
    """Reveal menu controls without following links and merge every DOM state."""
    navigation = await page.evaluate(_NAVIGATION_EXTRACTOR_JS)

    # Open the first navigation level before exploring dynamically mounted
    # controls. Otherwise a large first submenu can consume the exploration
    # budget before the remaining top-level entries are ever visited.
    primary_controls = page.locator(
        'nav > * > button[aria-expanded], nav > * > * > button[aria-expanded], '
        '[role="navigation"] > * > button[aria-expanded], '
        '[role="navigation"] > * > * > button[aria-expanded]'
    )
    for index in range(min(await primary_controls.count(), 24)):
        control = primary_controls.nth(index)
        try:
            await control.evaluate(
                "el => el.setAttribute('data-gyrus-navigation-inspected', 'true')"
            )
            await control.locator("xpath=..").hover(timeout=1_000)
            await page.wait_for_timeout(180)
            navigation = _merge_navigation_groups(
                navigation,
                await page.evaluate(_NAVIGATION_EXTRACTOR_JS),
            )
        except Exception as exc:
            logger.debug("Could not reveal a top-level navigation menu: %s", exc)

    for _ in range(24):
        controls = page.locator(
            'nav button[aria-expanded]:not([data-gyrus-navigation-inspected]), '
            '[role="navigation"] button[aria-expanded]:not([data-gyrus-navigation-inspected])'
        )
        if await controls.count() == 0:
            break

        selected = controls.first
        try:
            await selected.evaluate(
                "el => el.setAttribute('data-gyrus-navigation-inspected', 'true')"
            )
            await selected.locator("xpath=..").hover(timeout=1_000)
            await page.wait_for_timeout(180)
            if await selected.get_attribute("aria-expanded") == "false":
                await selected.click(timeout=1_000)
                await page.wait_for_timeout(120)
            navigation = _merge_navigation_groups(
                navigation,
                await page.evaluate(_NAVIGATION_EXTRACTOR_JS),
            )
        except Exception as exc:
            logger.debug("Could not reveal a navigation menu: %s", exc)

    return navigation


_NAVIGATION_EXTRACTOR_JS = r"""
() => {
  function textOf(el) {
    return (el?.innerText || el?.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 160);
  }
  function labelOf(el) {
    return textOf(el) || el?.getAttribute?.('aria-label') || '';
  }
  function absoluteUrl(value) {
    try { return value ? new URL(value, location.href).href : ''; } catch (_) { return value || ''; }
  }
  function directContainer(anchor, root) {
    let current = anchor;
    while (current.parentElement && current.parentElement !== root) current = current.parentElement;
    return current;
  }
  function itemFromContainer(container) {
    const control = container.matches?.('a[href]')
      ? container
      : container.querySelector(':scope > a[href], :scope > * > a[href]');
    if (!control) return null;
    const descendants = Array.from(container.querySelectorAll('a[href]'))
      .filter((anchor) => anchor !== control);
    const seen = new Set();
    const children = descendants.map((anchor) => {
      const url = absoluteUrl(anchor.getAttribute('href') || '');
      const label = labelOf(anchor) || url;
      const key = `${url}|${label}`;
      if (!label || seen.has(key)) return null;
      seen.add(key);
      return {label, url, children: []};
    }).filter(Boolean).slice(0, 160);
    const url = absoluteUrl(control.getAttribute('href') || '');
    return {label: labelOf(control) || url, url, children};
  }
  function itemFromListItem(item, depth = 0) {
    if (depth > 7) return null;
    const control = item.querySelector(':scope > a[href], :scope > * > a[href]');
    if (!control) return null;
    const childList = item.querySelector(':scope > ul, :scope > ol, :scope > * > ul, :scope > * > ol');
    const children = childList
      ? Array.from(childList.children)
          .filter((child) => child.matches('li'))
          .map((child) => itemFromListItem(child, depth + 1))
          .filter(Boolean)
      : [];
    const url = absoluteUrl(control.getAttribute('href') || '');
    return {label: labelOf(control) || url, url, children};
  }
  function itemsFromContainer(container) {
    const anchors = Array.from(container.querySelectorAll?.('a[href]') || []);
    const list = container.matches?.('ul, ol')
      ? container
      : container.querySelector?.(':scope > ul, :scope > ol');
    if (list) {
      return Array.from(list.children)
        .filter((child) => child.matches('li'))
        .map((child) => itemFromListItem(child))
        .filter(Boolean);
    }
    const ownsSubmenu = Array.from(container.querySelectorAll?.('button[aria-expanded]') || [])
      .some((button) => button.hasAttribute('aria-haspopup') || /menu|menü/i.test(button.getAttribute('aria-label') || ''));
    if (!ownsSubmenu && anchors.length > 1) {
      return anchors.map((anchor) => ({
        label: labelOf(anchor) || absoluteUrl(anchor.getAttribute('href') || ''),
        url: absoluteUrl(anchor.getAttribute('href') || ''),
        children: [],
      }));
    }
    const item = itemFromContainer(container);
    return item ? [item] : [];
  }

  return Array.from(document.querySelectorAll('nav, [role="navigation"]')).map((root, index) => {
    const containers = [];
    const seen = new Set();
    for (const anchor of root.querySelectorAll('a[href]')) {
      const container = directContainer(anchor, root);
      if (!seen.has(container)) {
        seen.add(container);
        containers.push(container);
      }
    }
    return {
      label: root.getAttribute('aria-label') || root.getAttribute('title') || `Navigation ${index + 1}`,
      items: containers.flatMap(itemsFromContainer).filter(Boolean).slice(0, 80),
    };
  }).filter((group) => group.items.length > 0).slice(0, 12);
}
"""


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

  // Custom properties, ordered so that the ones carrying a design decision
  // survive the cap applied further down.
  //
  // This used to ship the raw iteration order and slice it. Utility frameworks
  // register a large number of bookkeeping properties on :root (Tailwind alone
  // emits dozens of --tw-* placeholders holding "0 0 #0000" or an empty string),
  // and on such a site those could consume the entire budget, so the tokens the
  // page actually defines never left the browser at all. No amount of filtering
  // in the app can recover a value that was never sent.
  const rootStyles = window.getComputedStyle(document.documentElement);
  const meaningfulVariables = [];
  const placeholderVariables = [];
  // Values a framework parks on :root purely so a later rule can override them.
  const placeholderValues = new Set([
    '', '0', '0s', '0px', 'none', 'solid', 'initial', 'auto',
    // Lowercase throughout: matched against value.toLowerCase() below.
    '0 0 #0000', 'border-box', 'content-box', 'translatex(0)', 'translate(0)',
    'normal', '1', '100%',
  ]);
  for (const name of rootStyles) {
    if (!name.startsWith('--')) continue;
    const value = rootStyles.getPropertyValue(name).trim();
    const entry = {name, value};
    if (placeholderValues.has(value.toLowerCase())) {
      placeholderVariables.push(entry);
    } else {
      meaningfulVariables.push(entry);
    }
  }
  // Placeholders are kept rather than dropped: a site may legitimately define a
  // token whose value happens to look like one, and the app shows them in a
  // collapsed group. They just no longer crowd out the real tokens.
  const cssVariables = meaningfulVariables.concat(placeholderVariables);

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

  const runtimeProbe = Array.from(document.querySelectorAll('*')).slice(0, 500);
  const runtimeMarkers = [];
  const mark = (name, condition) => { if (condition) runtimeMarkers.push(name); };
  mark('WordPress', Boolean(
    document.querySelector('link[rel="https://api.w.org/"], link[href*="wp-json"], [class*="wp-block-"]')
  ));
  mark('Shopify', Boolean(window.Shopify || document.querySelector('[data-shopify]')));
  mark('Webflow', Boolean(
    window.Webflow || document.documentElement.hasAttribute('data-wf-page') ||
    document.documentElement.hasAttribute('data-wf-site')
  ));
  mark('Framer', Boolean(document.querySelector('[data-framer-name], [data-framer-component-type]')));
  mark('Drupal', Boolean(window.drupalSettings || document.querySelector('[data-drupal-selector]')));
  mark('Next.js', Boolean(document.querySelector('#__next, script#__NEXT_DATA__')));
  mark('Nuxt', Boolean(document.querySelector('#__nuxt') || window.__NUXT__));
  mark('Astro', Boolean(document.querySelector('astro-island, astro-slot')));
  mark('Gatsby', Boolean(document.querySelector('#___gatsby') || window.___gatsby));
  mark('SvelteKit', Boolean(document.querySelector('[data-sveltekit-preload-data], [data-sveltekit-preload-code]')));
  mark('Angular', Boolean(document.querySelector('[ng-version], app-root')));
  mark('Vue', Boolean(
    window.__VUE__ || document.querySelector('[data-v-app]') ||
    runtimeProbe.some((el) => Boolean(el.__vue_app__))
  ));
  mark('React', runtimeProbe.some((el) =>
    Object.keys(el).some((key) => key.startsWith('__reactFiber$') || key.startsWith('__reactContainer$'))
  ));
  mark('Tailwind CSS', cssVariables.some((item) => item.name.startsWith('--tw-')));
  const hasTanStackRouter = Boolean(document.querySelector('[data-route-announcer]'));
  mark('TanStack Router', hasTanStackRouter);
  mark('TanStack Start', hasTanStackRouter && Boolean(window.$R));
  mark('SSR + Hydration', hasTanStackRouter && Boolean(window.$R));
  mark('Radix UI', Boolean(document.querySelector('[data-radix-collection-item], [id^="radix-"]')));
  mark('Lucide', Boolean(document.querySelector('svg.lucide, [class*="lucide-"]')));
  mark('Plausible', scriptAssets.some((item) => /plausible(?:\.min)?\.js|plausible\.io/i.test(item.url)));
  mark('PWA Manifest', Boolean(document.querySelector('link[rel="manifest"]')));

  const markupHints = [];
  for (const attribute of Array.from(document.documentElement.attributes)) {
    if (attribute.name.startsWith('data-') || attribute.name === 'class') {
      markupHints.push(`${attribute.name}=${attribute.value}`.slice(0, 180));
    }
  }
  if (document.body?.className && typeof document.body.className === 'string') {
    markupHints.push(`body.class=${document.body.className}`.slice(0, 180));
  }
  const hasModulePreloads = Boolean(document.querySelector('link[rel="modulepreload"]'));
  const hasHashedEntry = scriptAssets.some((item) =>
    /\/assets\/(?:index|main|app)-[A-Za-z0-9_-]{6,}\.js(?:\?|$)/.test(item.url)
  );
  if (hasModulePreloads && hasHashedEntry) {
    markupHints.push('build=vite-build-assets');
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
    responsive_issues: responsiveIssues.slice(0, 40),
    _technology_signals: {
      generator: metaBy('meta[name="generator"], meta[property="generator"]'),
      runtime_markers: runtimeMarkers,
      script_urls: scriptAssets.map((item) => item.url).slice(0, 80),
      stylesheet_urls: styleAssets.map((item) => item.url).slice(0, 80),
      markup_hints: markupHints.slice(0, 20),
    },
  };
}
"""
