"""Palette derivation from rendered pixels."""

from collections import Counter
from typing import Iterable


def _bucket(pixel: tuple[int, int, int]) -> tuple[int, ...]:
    # Bucket to 16-level RGB steps so tiny anti-aliased differences collapse.
    return tuple(round(channel / 16) * 16 for channel in pixel)


def palette_from_pixels(
    pixels: Iterable[tuple[int, int, int]], max_colors: int = 8
) -> list[str]:
    """Return the most frequent design colors as ``#rrggbb`` strings."""
    counts = Counter(_bucket(pixel) for pixel in pixels)
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
