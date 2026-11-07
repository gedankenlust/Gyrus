"""The headless Chromium session used for one design inspection.

Everything here talks to Playwright. The timeouts are module-level lookups
at call time (not default arguments) so tests can tune them by patching
this module (e.g. ``browser.EVALUATE_TIMEOUT_SECONDS``).
"""

import asyncio
import logging
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, AsyncIterator, Callable

from services.outbound_url_security import validate_outbound_url
from services.safe_egress_proxy import SafeEgressProxy
from services.visual_snapshot.config import (
    CONTEXT_CLOSE_TIMEOUT_SECONDS,
    EVALUATE_TIMEOUT_SECONDS,
    MAX_SCREENSHOT_CSS_HEIGHT,
    MAX_SCREENSHOT_FILE_BYTES,
    MAX_SCREENSHOT_PIXELS,
    NETWORK_IDLE_TIMEOUT_MS,
    PAGE_LOAD_TIMEOUT_MS,
    SCREENSHOT_TIMEOUT_SECONDS,
    TOUCH_VIEWPORTS,
)
from services.visual_snapshot.extraction import DOCUMENT_HEIGHT_JS

logger = logging.getLogger(__name__)


class VisualSnapshotUnavailable(Exception):
    """Raised when the optional browser runtime needed for snapshots is absent."""


def load_playwright() -> Callable[[], Any]:
    """Return ``async_playwright`` or explain that the engine is missing.

    Imported lazily: Playwright is optional in some builds, and importing it
    at module load would make the whole backend fail to start without it.
    """
    try:
        from playwright.async_api import async_playwright
    except Exception as e:
        raise VisualSnapshotUnavailable(
            "The design engine is unavailable in this build. Reinstall or update "
            "Gyrus and try again."
        ) from e
    return async_playwright


async def evaluate(target, expression: str, *args: Any) -> Any:
    """page/locator.evaluate bounded by EVALUATE_TIMEOUT_SECONDS."""
    return await asyncio.wait_for(
        target.evaluate(expression, *args), timeout=EVALUATE_TIMEOUT_SECONDS
    )


def is_touch_viewport(viewport: dict[str, Any]) -> bool:
    return viewport["name"] in TOUCH_VIEWPORTS


@asynccontextmanager
async def chromium_session(
    async_playwright: Callable[[], Any], *, allowed_private_host: str | None
) -> AsyncIterator[Any]:
    """Launch Chromium whose every request leaves through the egress proxy.

    The proxy re-validates destinations at connect time, which the route
    guard alone cannot do (DNS can change between the check and the fetch).
    """
    async with SafeEgressProxy(allowed_private_host=allowed_private_host) as proxy:
        async with async_playwright() as p:
            browser = await p.chromium.launch(
                headless=True,
                proxy={"server": proxy.url, "bypass": ""},
                args=["--proxy-bypass-list=<-loopback>"],
            )
            try:
                yield browser
            finally:
                await browser.close()


def route_guard(
    allowed_private_host: str | None,
    dns_cache: dict[tuple[str, int], tuple[str, ...]],
):
    """A Playwright route handler that blocks requests to disallowed hosts."""

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

    return guard_route


async def open_viewport_context(browser, viewport: dict[str, Any], guard) -> Any:
    touch = is_touch_viewport(viewport)
    context = await browser.new_context(
        viewport={"width": viewport["width"], "height": viewport["height"]},
        device_scale_factor=viewport["device_scale_factor"],
        is_mobile=touch,
        has_touch=touch,
        accept_downloads=False,
        service_workers="block",
        permissions=[],
    )
    await context.route("**/*", guard)
    return context


def suppress_page_interruptions(page) -> None:
    """Dismiss dialogs and close popups so they cannot stall the capture."""

    async def dismiss_dialog(dialog):
        await dialog.dismiss()

    async def close_popup(popup):
        await popup.close()

    page.on("dialog", dismiss_dialog)
    page.on("popup", close_popup)


async def load_page(page, url: str) -> None:
    await page.goto(url, wait_until="domcontentloaded", timeout=PAGE_LOAD_TIMEOUT_MS)
    try:
        await page.wait_for_load_state("networkidle", timeout=NETWORK_IDLE_TIMEOUT_MS)
    except Exception as exc:
        logger.debug("Viewport did not reach network idle: %s", exc)


def bounded_screenshot_height(viewport: dict[str, Any], document_height: int) -> int:
    """Cap a full-page capture by CSS height and decoded output pixels."""
    width = max(1, int(viewport["width"]))
    scale = max(1, int(viewport.get("device_scale_factor", 1)))
    viewport_height = max(1, int(viewport["height"]))
    max_height_by_pixels = max(
        viewport_height,
        MAX_SCREENSHOT_PIXELS // (width * scale * scale),
    )
    return max(
        viewport_height,
        min(int(document_height), MAX_SCREENSHOT_CSS_HEIGHT, max_height_by_pixels),
    )


async def capture_screenshot(page, viewport: dict[str, Any], path: Path) -> tuple[int, int]:
    """Screenshot the page from the top; return (document height, captured height)."""
    document_height = int(await evaluate(page, DOCUMENT_HEIGHT_JS) or 0)
    capture_height = bounded_screenshot_height(viewport, document_height)
    await asyncio.wait_for(
        page.screenshot(
            path=str(path),
            # Without full_page Playwright clips to the visible viewport, however
            # tall the clip: every capture used to end at the first screen, so
            # nothing below it had a component thumbnail or issue evidence.
            # With full_page the clip applies to the whole page and keeps the
            # height and pixel bounds above.
            full_page=True,
            clip={
                "x": 0,
                "y": 0,
                "width": viewport["width"],
                "height": capture_height,
            },
        ),
        timeout=SCREENSHOT_TIMEOUT_SECONDS,
    )
    if path.stat().st_size > MAX_SCREENSHOT_FILE_BYTES:
        path.unlink(missing_ok=True)
        raise RuntimeError("Rendered page exceeds the screenshot safety limit")
    return document_height, capture_height


async def close_viewport(context, page) -> None:
    try:
        if context is not None:
            await asyncio.wait_for(context.close(), timeout=CONTEXT_CLOSE_TIMEOUT_SECONDS)
        elif page is not None:
            await asyncio.wait_for(page.close(), timeout=CONTEXT_CLOSE_TIMEOUT_SECONDS)
    except asyncio.TimeoutError:
        # browser.close() in chromium_session still tears the renderer down.
        logger.warning("Closing a hung design inspection page timed out")
