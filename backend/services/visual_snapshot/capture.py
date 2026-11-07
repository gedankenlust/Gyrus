"""Orchestrates one design inspection across all viewport presets.

Per viewport: open an isolated context, render, screenshot, extract, derive
screenshot artifacts, assemble the document. Then map the website structure
and persist the run. Blocking file and image work runs in worker threads so
a capture never stalls the event loop that also serves the app's requests.
"""

import asyncio
import logging
from pathlib import Path
from typing import Any, Callable

from services.outbound_url_security import explicit_private_hostname, validate_outbound_url
from services.visual_snapshot.browser import (
    capture_screenshot,
    chromium_session,
    close_viewport,
    evaluate,
    is_touch_viewport,
    load_page,
    load_playwright,
    open_viewport_context,
    route_guard,
    suppress_page_interruptions,
)
from services.visual_snapshot.config import (
    DESIGN_INSPECTION_STEPS,
    NAVIGATION_EXPLORATION_TIMEOUT_SECONDS,
    VIEWPORTS,
)
from services.visual_snapshot.document import (
    assemble_viewport,
    capture_status,
    new_snapshot,
    site_structure_failure,
    viewport_error,
)
from services.visual_snapshot.extraction import (
    VISUAL_EXTRACTOR_JS,
    extractor_arguments,
    split_extraction,
)
from services.visual_snapshot.imaging import attach_issue_evidence, dominant_colors
from services.visual_snapshot.navigation import capture_rendered_navigation
from services.visual_snapshot.persistence import (
    is_promotable,
    new_snapshot_run_id,
    prepare_run_dir,
    run_file_url,
    store_run,
)
from services.visual_snapshot.recorder import PageRecorder

logger = logging.getLogger(__name__)

ProgressCallback = Callable[[str, int, int], None]


async def _write_in_thread(func: Callable[..., Any], *args: Any) -> Any:
    """Run blocking writes into the run directory to completion.

    A cancelled inspection is cleaned up by deleting its run directory
    (visual_snapshot_job_service). That must not race with a worker thread
    still writing into it, so on cancellation this waits for the thread to
    finish before the CancelledError continues to propagate.
    """
    future = asyncio.ensure_future(asyncio.to_thread(func, *args))
    try:
        return await asyncio.shield(future)
    except asyncio.CancelledError:
        while not future.done():
            try:
                await asyncio.wait({future})
            except asyncio.CancelledError:
                continue
        raise


async def _capture_viewport(
    browser,
    viewport: dict[str, Any],
    *,
    url: str,
    guard,
    bookmark_id: str,
    run_id: str,
    out_dir: Path,
    explore_navigation: bool,
) -> tuple[dict[str, Any], list[dict[str, Any]] | None]:
    """Capture one viewport; return its document and, if asked, the navigation."""
    context = None
    page = None
    try:
        context = await open_viewport_context(browser, viewport, guard)
        page = await context.new_page()
        recorder = PageRecorder()
        recorder.attach(page)
        suppress_page_interruptions(page)

        await load_page(page, url)
        await recorder.finish_script_probes()

        screenshot_name = f"{viewport['name']}.png"
        screenshot_path = out_dir / screenshot_name
        document_height, capture_height = await capture_screenshot(page, viewport, screenshot_path)

        raw = await evaluate(
            page,
            VISUAL_EXTRACTOR_JS,
            extractor_arguments(viewport, is_touch=is_touch_viewport(viewport)),
        )
        extracted, technology_signals = split_extraction(raw)
        await _write_in_thread(
            attach_issue_evidence,
            extracted.get("responsive_issues") or [],
            screenshot_path,
            out_dir,
            bookmark_id,
            run_id,
            viewport["name"],
            viewport["device_scale_factor"],
        )
        palette = await asyncio.to_thread(dominant_colors, screenshot_path)
        data = assemble_viewport(
            extracted,
            technology_signals,
            viewport,
            screenshot_name=screenshot_name,
            screenshot_url=run_file_url(bookmark_id, run_id, screenshot_name),
            screenshot_truncated=document_height > capture_height,
            dominant_colors=palette,
            network_entries=recorder.network_entries,
            console_messages=recorder.console_messages,
            script_content_markers=recorder.script_content_markers,
            technology_versions=recorder.technology_versions,
        )

        # Menus are opened by hovering/clicking. Do it only after the
        # screenshot and the element/issue extraction, so those show the page
        # as a visitor first sees it rather than with dropdowns expanded. A
        # failure here must not discard the viewport that was already captured.
        navigation = None
        if explore_navigation:
            try:
                navigation = await asyncio.wait_for(
                    capture_rendered_navigation(page),
                    timeout=NAVIGATION_EXPLORATION_TIMEOUT_SECONDS,
                )
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                logger.debug("Navigation exploration failed: %s", exc)
        return data, navigation
    finally:
        await close_viewport(context, page)


async def _site_structure(bookmark_id: str, url: str) -> dict[str, Any]:
    try:
        # Imported lazily so importing the snapshot package does not load the
        # crawler (and scraper_service with it).
        from services.site_structure_service import site_structure_service

        structure_data = await site_structure_service.data_for_url(
            bookmark_id,
            url,
            force_refresh=True,
        )
        return site_structure_service.snapshot_payload(structure_data)
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        logger.warning("Could not map website structure for %s: %s", url, exc)
        return site_structure_failure(url, exc)


async def capture_snapshot(
    bookmark_id: str,
    url: str,
    title: str = "",
    *,
    run_id: str | None = None,
    on_progress: ProgressCallback | None = None,
) -> dict[str, Any]:
    async_playwright = load_playwright()

    run_id = run_id or new_snapshot_run_id()
    allowed_private_host = explicit_private_hostname(url)
    await validate_outbound_url(url, allowed_private_host=allowed_private_host)
    dns_cache: dict[tuple[str, int], tuple[str, ...]] = {}
    out_dir = await _write_in_thread(prepare_run_dir, bookmark_id, run_id)

    snapshot = new_snapshot(bookmark_id, run_id, url, title)

    if on_progress:
        on_progress("launching", 0, DESIGN_INSPECTION_STEPS)

    guard = route_guard(allowed_private_host, dns_cache)
    async with chromium_session(async_playwright, allowed_private_host=allowed_private_host) as browser:
        for index, viewport in enumerate(VIEWPORTS):
            try:
                if on_progress:
                    on_progress(viewport["name"], index, DESIGN_INSPECTION_STEPS)
                data, navigation = await _capture_viewport(
                    browser,
                    viewport,
                    url=url,
                    guard=guard,
                    bookmark_id=bookmark_id,
                    run_id=run_id,
                    out_dir=out_dir,
                    explore_navigation=viewport["name"] == "desktop" and not snapshot["navigation"],
                )
                if navigation is not None:
                    snapshot["navigation"] = navigation
                snapshot["viewports"].append(data)
            except Exception as e:
                snapshot["errors"].append(viewport_error(viewport, e))

    if on_progress:
        on_progress("site_structure", len(VIEWPORTS), DESIGN_INSPECTION_STEPS)
    snapshot["site_structure"] = await _site_structure(bookmark_id, url)

    snapshot["status"] = capture_status(snapshot)
    snapshot["promoted"] = is_promotable(snapshot)
    await _write_in_thread(store_run, bookmark_id, snapshot)
    if on_progress:
        on_progress("finished", DESIGN_INSPECTION_STEPS, DESIGN_INSPECTION_STEPS)
    return snapshot
