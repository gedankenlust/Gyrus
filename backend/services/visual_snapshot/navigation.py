"""Menu exploration on the rendered desktop page.

Menus are revealed by hovering and clicking their toggles, never by following
links, and every revealed DOM state is merged into one navigation tree.
"""

import logging
from typing import Any

from services.visual_snapshot.analysis.navigation import merge_navigation_groups
from services.visual_snapshot.browser import evaluate
from services.visual_snapshot.extraction import (
    MARK_NAVIGATION_CONTROL_JS,
    NAVIGATION_EXTRACTOR_JS,
)

logger = logging.getLogger(__name__)

MAX_MENU_CONTROLS = 24
HOVER_TIMEOUT_MS = 1_000
CLICK_TIMEOUT_MS = 1_000
HOVER_SETTLE_MS = 180
CLICK_SETTLE_MS = 120

_PRIMARY_CONTROLS = (
    'nav > * > button[aria-expanded], nav > * > * > button[aria-expanded], '
    '[role="navigation"] > * > button[aria-expanded], '
    '[role="navigation"] > * > * > button[aria-expanded]'
)
_UNINSPECTED_CONTROLS = (
    'nav button[aria-expanded]:not([data-gyrus-navigation-inspected]), '
    '[role="navigation"] button[aria-expanded]:not([data-gyrus-navigation-inspected])'
)


async def capture_rendered_navigation(page) -> list[dict[str, Any]]:
    """Reveal menu controls without following links and merge every DOM state."""
    navigation = await evaluate(page, NAVIGATION_EXTRACTOR_JS)

    # Open the first navigation level before exploring dynamically mounted
    # controls. Otherwise a large first submenu can consume the exploration
    # budget before the remaining top-level entries are ever visited.
    primary_controls = page.locator(_PRIMARY_CONTROLS)
    for index in range(min(await primary_controls.count(), MAX_MENU_CONTROLS)):
        control = primary_controls.nth(index)
        try:
            await evaluate(control, MARK_NAVIGATION_CONTROL_JS)
            await control.locator("xpath=..").hover(timeout=HOVER_TIMEOUT_MS)
            await page.wait_for_timeout(HOVER_SETTLE_MS)
            navigation = merge_navigation_groups(
                navigation,
                await evaluate(page, NAVIGATION_EXTRACTOR_JS),
            )
        except Exception as exc:
            logger.debug("Could not reveal a top-level navigation menu: %s", exc)

    for _ in range(MAX_MENU_CONTROLS):
        controls = page.locator(_UNINSPECTED_CONTROLS)
        if await controls.count() == 0:
            break

        selected = controls.first
        try:
            await evaluate(selected, MARK_NAVIGATION_CONTROL_JS)
            await selected.locator("xpath=..").hover(timeout=HOVER_TIMEOUT_MS)
            await page.wait_for_timeout(HOVER_SETTLE_MS)
            if await selected.get_attribute("aria-expanded") == "false":
                await selected.click(timeout=CLICK_TIMEOUT_MS)
                await page.wait_for_timeout(CLICK_SETTLE_MS)
            navigation = merge_navigation_groups(
                navigation,
                await evaluate(page, NAVIGATION_EXTRACTOR_JS),
            )
        except Exception as exc:
            logger.debug("Could not reveal a navigation menu: %s", exc)

    return navigation
