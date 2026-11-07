"""Pure HTML / JSON parsing for Reader text extraction.

No network and no I/O: these functions turn an already downloaded page into
Reader text. Several are CPU-heavy on large pages, so callers run them in a
worker thread (`asyncio.to_thread`), never directly on the event loop.
services/scraper_service.py does the bounded, guarded downloading.
"""
import json
from typing import Any, Dict, Optional

from bs4 import BeautifulSoup
from readability import Document

_JSONLD_READER_NOISE = {
    "about", "author", "breadcrumb", "dateCreated", "dateModified",
    "datePublished", "description", "headline", "inLanguage",
    "isPartOf", "itemListElement", "keywords", "mainEntityOfPage",
    "potentialAction", "publisher",
}


def _extract_json_object(text: str, start: int) -> Optional[str]:
    """Return the JSON object that begins at `start` ('{'), respecting strings
    and escapes so braces inside string values don't end it early."""
    depth = 0
    in_str = False
    esc = False
    for i in range(start, len(text)):
        c = text[i]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
        else:
            if c == '"':
                in_str = True
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    return text[start: i + 1]
    return None


def _flatten_jsonld(obj: Any, lines: list, key: str = "", depth: int = 0) -> None:
    """Walk a schema.org JSON-LD object and collect 'key: value' fact lines.

    Many data-rich pages (sports profiles, products, recipes) embed their facts
    here even when the visible text is rendered later by JavaScript — so this is
    often the only place a value like a player's height actually appears."""
    if depth > 5:
        return
    if isinstance(obj, dict):
        # schema.org QuantitativeValue → "height: 188 cm"
        if "value" in obj and ("unitText" in obj or "unitCode" in obj):
            unit = obj.get("unitText") or obj.get("unitCode") or ""
            lines.append(f"{key}: {obj['value']} {unit}".strip())
            return
        for k, v in obj.items():
            if (
                k.startswith("@")
                or k in _JSONLD_READER_NOISE
                or k in ("image", "logo", "url", "sameAs", "contentUrl", "thumbnailUrl")
            ):
                continue
            _flatten_jsonld(v, lines, f"{key} {k}".strip(), depth + 1)
    elif isinstance(obj, list):
        for item in obj[:10]:
            _flatten_jsonld(item, lines, key, depth + 1)
    elif isinstance(obj, (str, int, float, bool)):
        s = str(obj).strip()
        if s and key and len(s) < 300:
            lines.append(f"{key}: {s}")


def _extract_jsonld_facts(soup: BeautifulSoup) -> str:
    lines: list = []
    for tag in soup.find_all("script", type="application/ld+json"):
        raw = tag.string or tag.get_text()
        if not raw:
            continue
        try:
            data = json.loads(raw)
        except Exception:
            continue
        objs = data if isinstance(data, list) else [data]
        expanded = []
        for o in objs:
            if isinstance(o, dict) and isinstance(o.get("@graph"), list):
                expanded.extend(o["@graph"])
            else:
                expanded.append(o)
        for o in expanded:
            _flatten_jsonld(o, lines)
    # De-duplicate while preserving order, and cap to keep the prompt lean.
    seen, out = set(), []
    for line in lines:
        if line not in seen:
            seen.add(line)
            out.append(line)
    return "\n".join(out[:60])


def _find_all_keys(obj: Any, key: str, out: list, depth: int = 0) -> None:
    if depth > 14 or len(out) >= 5:
        return
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == key:
                out.append(v)
            _find_all_keys(v, key, out, depth + 1)
    elif isinstance(obj, list):
        for item in obj:
            _find_all_keys(item, key, out, depth + 1)


def _next_data(html: str) -> Optional[dict]:
    """Parse a Next.js page's embedded __NEXT_DATA__ JSON — many data-heavy
    sites (e.g. FotMob) server-render their tables into it even though the
    visible page builds them with JavaScript."""
    marker = 'id="__NEXT_DATA__"'
    idx = html.find(marker)
    if idx == -1:
        return None
    brace = html.find("{", idx)
    if brace == -1:
        return None
    raw = _extract_json_object(html, brace)
    if not raw:
        return None
    try:
        return json.loads(raw)
    except Exception:
        return None


def _extract_career_history(next_data: dict) -> str:
    """Render a player's senior career table (club, period, apps, goals)."""
    found: list = []
    _find_all_keys(next_data, "careerHistory", found)
    lines: list = []
    for ch in found:
        senior = (ch or {}).get("careerItems", {}).get("senior", {})
        for e in senior.get("teamEntries", []):
            team = e.get("team", "")
            if not team:
                continue
            start = (e.get("startDate") or "")[:7]
            end = (e.get("endDate") or "")[:7] or "present"
            apps = e.get("appearances", "?")
            goals = e.get("goals", "?")
            assists = e.get("assists", "?")
            transfer = (e.get("transferType") or {}).get("text")
            extra = f" [{transfer}]" if transfer else ""
            lines.append(
                f"{team} ({start}–{end}){extra}: {apps} appearances, {goals} goals, {assists} assists"
            )
        if lines:
            break
    return "\n".join(lines[:40])


def _player_response(html: str) -> Optional[dict]:
    marker = "ytInitialPlayerResponse"
    idx = html.find(marker)
    if idx == -1:
        return None
    brace = html.find("{", idx)
    if brace == -1:
        return None
    raw = _extract_json_object(html, brace)
    if not raw:
        return None
    try:
        return json.loads(raw)
    except Exception:
        return None


_BLOCK_TAGS = {
    "p", "h1", "h2", "h3", "h4", "h5", "h6",
    "li", "blockquote", "pre", "figcaption", "br",
}


def _structured_text(soup: BeautifulSoup) -> str:
    """Turn the cleaned article HTML into readable Markdown-ish plain text,
    preserving paragraphs, headings and list items.

    The old approach (`get_text(separator="\\n")`) inserted a newline between
    *every* inline node, which shredded sentences into ragged fragments — the
    "buggy" look in the reader. Walking block-level elements instead keeps each
    paragraph on one line and separates blocks with a blank line."""
    lines: list[str] = []

    def emit(text: str, prefix: str = "") -> None:
        # Collapse internal whitespace so inline spans don't add stray breaks.
        cleaned = " ".join(text.split())
        if cleaned:
            lines.append(prefix + cleaned)

    body = soup.body or soup
    for el in body.find_all(_BLOCK_TAGS):
        name = el.name.lower()
        if name == "br":
            continue
        # Skip a block that only wraps other blocks — its children are handled
        # on their own, so emitting here would duplicate the text.
        if el.find(_BLOCK_TAGS - {"br"}):
            continue
        if name in ("h1", "h2", "h3", "h4", "h5", "h6"):
            level = int(name[1])
            emit(el.get_text(" ", strip=True), prefix="#" * level + " ")
        elif name == "li":
            emit(el.get_text(" ", strip=True), prefix="- ")
        elif name == "blockquote":
            emit(el.get_text(" ", strip=True), prefix="> ")
        else:  # p, pre, figcaption
            emit(el.get_text(" ", strip=True))

    # Fall back to flat text only when NO block structure was found at all
    # (unusual markup) — never just because the content is legitimately short.
    if not lines:
        return soup.get_text("\n", strip=True)
    return "\n\n".join(lines)


def _parse_reader_document(html: str) -> Dict[str, str]:
    """CPU-bound Reader parsing, designed to run outside the event loop."""
    full_soup = BeautifulSoup(html, "html.parser")
    doc = Document(html)
    title = doc.short_title()
    summary_html = doc.summary()

    clean_soup = BeautifulSoup(summary_html, "html.parser")
    for table in clean_soup.find_all("table"):
        links = table.find_all("a")
        rows = table.find_all("tr")
        if len(links) > 10 or len(rows) > 20:
            table.decompose()

    body_text = _structured_text(clean_soup)
    parts = []
    meta_desc = (
        full_soup.find("meta", attrs={"name": "description"})
        or full_soup.find("meta", property="og:description")
    )
    if meta_desc and meta_desc.get("content"):
        parts.append(f"Summary: {meta_desc['content'].strip()}")

    facts = _extract_jsonld_facts(full_soup)
    if facts:
        parts.append(f"Key facts:\n{facts}")

    next_data = _next_data(html)
    if next_data:
        career = _extract_career_history(next_data)
        if career:
            parts.append(f"Career history:\n{career}")

    if body_text:
        parts.append(body_text)

    headings = [
        f"{heading.name}: {heading.get_text(strip=True)}"
        for heading in full_soup.find_all(["h1", "h2", "h3"])[:20]
    ]
    return {
        "content": "\n\n".join(parts)[:12_000],
        "structural_summary": "\n".join(headings),
        "title": title,
    }


def _parse_youtube_page(html: str) -> tuple[str, str, Optional[dict]]:
    """(og:title, og:description, ytInitialPlayerResponse) of a watch page.
    CPU-bound (a watch page is ~1 MB of HTML), so it runs outside the loop."""
    soup = BeautifulSoup(html, "html.parser")
    og_title = soup.find("meta", property="og:title")
    og_desc = soup.find("meta", property="og:description")
    title = og_title["content"] if og_title and og_title.get("content") else ""
    description = og_desc["content"] if og_desc and og_desc.get("content") else ""
    return title, description, _player_response(html)
