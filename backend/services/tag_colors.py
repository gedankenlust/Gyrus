"""
Collision-avoiding color assignment for tags.

Auto-tagging can create many tags across one run, and the old scheme (hash
the tag name, index into a 10-color palette) collided constantly once a
library had more than ~8 tags — the birthday paradox against a small
palette. `next_color` instead looks at what colors are actually in use and
picks one that isn't, so tags only repeat once every palette color has
already been assigned at least once (which in practice never happens: once
the curated palette is exhausted, it keeps generating new maximally-distinct
hues via golden-angle spacing).
"""
import colorsys
from sqlalchemy.orm import Session
from models.tag import Tag

# Hand-picked, vivid, dark-background-friendly hues — chosen to be pairwise
# distinguishable at a glance (no two entries are shades of the same hue).
PALETTE = [
    "#8B5CF6",  # violet
    "#3B82F6",  # blue
    "#10B981",  # emerald
    "#F59E0B",  # amber
    "#EF4444",  # red
    "#EC4899",  # pink
    "#14B8A6",  # teal
    "#F97316",  # orange
    "#6366F1",  # indigo
    "#84CC16",  # lime
    "#06B6D4",  # cyan
    "#D946EF",  # fuchsia
    "#EAB308",  # yellow
    "#22C55E",  # green
    "#F43F5E",  # rose
    "#0EA5E9",  # sky
    "#A855F7",  # purple
    "#65A30D",  # olive
    "#DC2626",  # dark red
    "#7C3AED",  # deep violet
    "#059669",  # dark emerald
    "#EA580C",  # dark orange
    "#0891B2",  # dark cyan
    "#BE185D",  # dark rose
]

GOLDEN_ANGLE = 137.508  # degrees — spaces generated hues maximally apart


def _hsl_hex(hue_deg: float, saturation: float = 0.62, lightness: float = 0.55) -> str:
    r, g, b = colorsys.hls_to_rgb((hue_deg % 360) / 360, lightness, saturation)
    return "#{:02X}{:02X}{:02X}".format(round(r * 255), round(g * 255), round(b * 255))


def _generated(index: int) -> str:
    """A hue-spaced color beyond the curated palette, for the (rare) case a
    library has more tags than PALETTE has entries."""
    return _hsl_hex(index * GOLDEN_ANGLE)


def next_color(db: Session) -> str:
    """The first palette color not currently used by any tag. Call this
    once per new tag — after it's added to the session (a flush makes it
    visible to this query), the next call correctly skips it too."""
    used = {c for (c,) in db.query(Tag.color).filter(Tag.color.isnot(None)).all()}
    for c in PALETTE:
        if c not in used:
            return c
    n = len(used)
    for i in range(n, n + 1000):
        c = _generated(i)
        if c not in used:
            return c
    return PALETTE[0]  # unreachable in practice


def rebalanced(names: list[str]) -> dict[str, str]:
    """Assign every name a distinct color in one pass (sorted for a
    deterministic, reproducible result), extending past the curated palette
    with generated hues if needed. Used to repair a tag set that already
    collided under the old hash-based scheme."""
    return {
        name: (PALETTE[i] if i < len(PALETTE) else _generated(i))
        for i, name in enumerate(sorted(names))
    }
