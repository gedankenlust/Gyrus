import html as html_lib
import json
import logging
import re
from urllib.parse import urlparse

import httpx
from bs4 import BeautifulSoup
from readability import Document
from typing import Dict, Any, Optional

logger = logging.getLogger(__name__)

# A browser-like User-Agent: YouTube (and many sites) serve much richer HTML to
# a real browser UA than to an obvious bot, which is what we need for scraping.
_BROWSER_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)


def _is_youtube(url: str) -> bool:
    host = urlparse(url).netloc.lower()
    return host.endswith("youtube.com") or host.endswith("youtu.be")


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
            if k.startswith("@") or k in ("image", "logo", "url", "sameAs", "contentUrl", "thumbnailUrl"):
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


class ScraperService:
    def __init__(self):
        self.timeout = httpx.Timeout(15.0)
        self.headers = {
            "User-Agent": _BROWSER_UA,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
        }

    async def extract_content(self, url: str) -> Dict[str, Any]:
        """
        Extracts the main content and structural summary from a URL.
        """
        result = {
            "content": "",
            "structural_summary": "",
            "title": "",
            "error": None
        }

        try:
            async with httpx.AsyncClient(timeout=self.timeout, follow_redirects=True, headers=self.headers) as client:
                if _is_youtube(url):
                    yt = await self._extract_youtube(url, client)
                    if yt.get("content"):
                        return yt
                    # Fall through to generic scraping if YouTube extraction
                    # produced nothing useful.

                response = await client.get(url)
                response.raise_for_status()
                html = response.text

                full_soup = BeautifulSoup(html, "html.parser")

                # Use readability to extract the main article text
                doc = Document(html)
                result["title"] = doc.short_title()
                summary_html = doc.summary()
                
                # Filter out likely navigational/noisy tables from the readability summary
                clean_soup = BeautifulSoup(summary_html, "html.parser")
                for table in clean_soup.find_all("table"):
                    # Heuristic: large tables or tables with many links are often navigational
                    links = table.find_all("a")
                    rows = table.find_all("tr")
                    if len(links) > 10 or len(rows) > 20:
                        table.decompose()
                
                # Preserve paragraph/heading/list structure instead of flattening
                # every inline node onto its own line (which looked shredded).
                body_text = _structured_text(clean_soup)

                # Prepend facts ONLY if they aren't already dominant in the body
                parts = []
                meta_desc = (full_soup.find("meta", attrs={"name": "description"})
                             or full_soup.find("meta", property="og:description"))
                if meta_desc and meta_desc.get("content"):
                    parts.append(f"Summary: {meta_desc['content'].strip()}")
                
                # For Wikipedia and similar, 'Key facts' often duplicates the body
                # or adds noise. We keep them but cap them strictly.
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

                result["content"] = "\n\n".join(parts)[:12000]

                # Extract structural summary (headings)
                headings = []
                for h in full_soup.find_all(["h1", "h2", "h3"]):
                    headings.append(f"{h.name}: {h.get_text(strip=True)}")

                result["structural_summary"] = "\n".join(headings[:20]) # Limit to top 20 headings

        except Exception as e:
            logger.error(f"Error scraping {url}: {e}")
            result["error"] = str(e)

        return result

    async def _extract_youtube(self, url: str, client: httpx.AsyncClient) -> Dict[str, Any]:
        """YouTube watch pages are JS apps — readability gets almost nothing.
        Instead pull the video's title, full description and (if available) the
        caption transcript, which is what actually lets the LLM summarize it."""
        result = {"content": "", "structural_summary": "", "title": "", "error": None}
        try:
            response = await client.get(url)
            response.raise_for_status()
            html = response.text

            soup = BeautifulSoup(html, "html.parser")
            og_title = soup.find("meta", property="og:title")
            og_desc = soup.find("meta", property="og:description")
            title = og_title["content"] if og_title and og_title.get("content") else ""
            description = og_desc["content"] if og_desc and og_desc.get("content") else ""

            player = _player_response(html)
            channel = ""
            transcript = ""
            if player:
                details = player.get("videoDetails", {})
                title = title or details.get("title", "")
                channel = details.get("author", "")
                short_desc = details.get("shortDescription", "")
                if len(short_desc) > len(description):
                    description = short_desc
                transcript = await self._fetch_youtube_transcript(player, client)

            result["title"] = title
            parts = []
            if title:
                parts.append(f"Video title: {title}")
            if channel:
                parts.append(f"Channel: {channel}")
            if description:
                parts.append(f"Description:\n{description}")
            if transcript:
                parts.append(f"Transcript:\n{transcript}")
            result["content"] = "\n\n".join(parts)[:15000]
            result["structural_summary"] = title
        except Exception as e:
            logger.error(f"Error scraping YouTube {url}: {e}")
            result["error"] = str(e)
        return result

    async def _fetch_youtube_transcript(self, player: dict, client: httpx.AsyncClient) -> str:
        """Fetch and flatten the caption track (prefer English) into plain text."""
        try:
            tracks = (
                player.get("captions", {})
                .get("playerCaptionsTracklistRenderer", {})
                .get("captionTracks", [])
            )
            if not tracks:
                return ""
            chosen = next(
                (t for t in tracks if t.get("languageCode", "").startswith("en")),
                tracks[0],
            )
            base_url = chosen.get("baseUrl")
            if not base_url:
                return ""
            resp = await client.get(base_url)
            if resp.status_code != 200 or not resp.text:
                return ""
            # The timedtext response is XML: <text start=...>line</text> ...
            segments = re.findall(r"<text[^>]*>(.*?)</text>", resp.text, re.DOTALL)
            # Captions are double-escaped (e.g. &amp;#39;), so unescape twice.
            lines = [html_lib.unescape(html_lib.unescape(s)).strip() for s in segments]
            transcript = " ".join(line for line in lines if line)
            return transcript[:12000]
        except Exception as e:
            logger.debug("transcript fetch failed: %s", e)
            return ""

    async def get_pagespeed_metrics(self, url: str) -> Dict[str, Any]:
        """
        Fetch Core Web Vitals and PageSpeed metrics using the Google PageSpeed Insights API.
        """
        api_url = "https://www.googleapis.com/pagespeedonline/v5/runPagespeed"
        params = {
            "url": url,
            "category": ["PERFORMANCE"],
            # No API key for now (public usage limits apply)
        }
        
        result = {
            "lcp": None, # Largest Contentful Paint
            "cls": None, # Cumulative Layout Shift
            "fid": None, # First Input Delay (or equivalent)
            "score": None,
            "error": None
        }
        
        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                response = await client.get(api_url, params=params)
                if response.status_code == 200:
                    data = response.json()
                    
                    # Core Web Vitals (Loading Experience)
                    loading_exp = data.get("loadingExperience", {}).get("metrics", {})
                    result["lcp"] = loading_exp.get("LARGEST_CONTENTFUL_PAINT_MS", {}).get("percentile")
                    result["cls"] = loading_exp.get("CUMULATIVE_LAYOUT_SHIFT_SCORE", {}).get("percentile")
                    result["fid"] = loading_exp.get("FIRST_INPUT_DELAY_MS", {}).get("percentile")
                    
                    # Performance Score
                    result["score"] = data.get("lighthouseResult", {}).get("categories", {}).get("performance", {}).get("score")
                else:
                    logger.warning(f"PageSpeed API returned status {response.status_code} for {url}")
                    result["error"] = f"API returned {response.status_code}"
        except Exception as e:
            logger.error(f"Error fetching PageSpeed metrics for {url}: {e}")
            result["error"] = str(e)
            
        return result

scraper_service = ScraperService()
