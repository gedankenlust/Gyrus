import asyncio
import hashlib
import html as html_lib
import json
import logging
import re
import time
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urljoin, urlparse, urlunparse

import httpx
from bs4 import BeautifulSoup

from database import DATA_DIR
from services.scraper_service import _BROWSER_UA

logger = logging.getLogger(__name__)

CACHE_VERSION = 2


_ASSET_EXTENSIONS = {
    ".7z", ".avi", ".css", ".csv", ".doc", ".docx", ".gif", ".ico", ".jpeg",
    ".jpg", ".js", ".json", ".mp3", ".mp4", ".pdf", ".png", ".rar", ".rss",
    ".svg", ".tar", ".tgz", ".ttf", ".txt", ".webm", ".webp", ".woff",
    ".woff2", ".xls", ".xlsx", ".xml", ".zip",
}


@dataclass
class FetchResult:
    url: str
    content_type: str
    text: str


class SiteStructureService:
    """Discover same-origin HTML pages for AI Brain structure questions."""

    def __init__(self) -> None:
        self.cache_dir: Path = DATA_DIR / "site_structure"
        self.cache_ttl_seconds = 24 * 60 * 60
        self.max_pages = 80
        self.deadline_seconds = 16
        self.timeout = httpx.Timeout(7.0, connect=4.0)
        self.headers = {
            "User-Agent": _BROWSER_UA,
            "Accept-Language": "en-US,en;q=0.9,de;q=0.8",
        }

    def should_include_for_prompt(self, prompt: str | None) -> bool:
        text = (prompt or "").lower()
        needles = (
            "wie viele seiten",
            "wieviele seiten",
            "wie viel seiten",
            "anzahl der seiten",
            "seiten hat",
            "seiten gibt",
            "unterseiten",
            "alle seiten",
            "seitenstruktur",
            "website-struktur",
            "site struktur",
            "sitemap",
            "site map",
            "interne links",
            "interne seiten",
            "how many pages",
            "number of pages",
            "site structure",
            "internal pages",
            "internal links",
        )
        return any(needle in text for needle in needles)

    def is_page_count_prompt(self, prompt: str | None) -> bool:
        text = " ".join((prompt or "").lower().split())
        count_needles = (
            "wie viele seiten",
            "wieviele seiten",
            "wie viel seiten",
            "anzahl der seiten",
            "seiten hat",
            "seiten gibt",
            "how many pages",
            "number of pages",
        )
        return any(needle in text for needle in count_needles)

    async def context_for_url(
        self,
        bookmark_id: str,
        url: str,
        *,
        force_refresh: bool = False,
    ) -> str:
        data = await self.data_for_url(bookmark_id, url, force_refresh=force_refresh)
        return self._format_context(data)

    async def data_for_url(
        self,
        bookmark_id: str,
        url: str,
        *,
        force_refresh: bool = False,
    ) -> dict:
        cached = None if force_refresh else self._read_cache(bookmark_id, url)
        data = cached or await self.crawl(url)
        if not cached:
            self._write_cache(bookmark_id, url, data)
        return data

    async def page_count_answer_for_url(
        self,
        bookmark_id: str,
        url: str,
        *,
        language: str | None = None,
        force_refresh: bool = False,
    ) -> str:
        data = await self.data_for_url(bookmark_id, url, force_refresh=force_refresh)
        return self._format_page_count_answer(data, language=language)

    async def crawl(self, start_url: str) -> dict:
        parsed = urlparse(start_url)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            return {
                "url": start_url,
                "origin": "",
                "pages": [],
                "limit": self.max_pages,
                "limit_reached": False,
                "errors": ["Only http:// and https:// URLs can be crawled."],
            }

        origin = f"{parsed.scheme}://{parsed.netloc}"
        deadline = time.monotonic() + self.deadline_seconds
        pages: dict[str, dict] = {}
        seen: set[str] = set()
        queued: set[str] = set()
        queue: list[str] = []
        sitemap_urls: list[str] = []
        sitemap_sources: list[str] = []
        errors: list[str] = []

        def enqueue(candidate: str | None) -> None:
            normalized = self._normalize_internal_url(candidate, origin, start_url)
            if not normalized or normalized in seen or normalized in queued:
                return
            if len(queued) + len(seen) >= self.max_pages * 4:
                return
            queued.add(normalized)
            queue.append(normalized)

        start_normalized = self._normalize_internal_url(start_url, origin, start_url) or start_url
        enqueue(start_normalized)

        async with httpx.AsyncClient(
            timeout=self.timeout,
            follow_redirects=True,
            headers=self.headers,
        ) as client:
            sitemap_urls, sitemap_sources = await self._discover_sitemap_urls(client, origin)
            for sitemap_url in sitemap_urls[: self.max_pages]:
                enqueue(sitemap_url)

            while queue and len(pages) < self.max_pages and time.monotonic() < deadline:
                batch: list[str] = []
                while queue and len(batch) < 6 and len(pages) + len(batch) < self.max_pages:
                    current = queue.pop(0)
                    queued.discard(current)
                    if current in seen:
                        continue
                    seen.add(current)
                    batch.append(current)

                results = await asyncio.gather(
                    *[
                        self._fetch_text(
                            client,
                            item,
                            "text/html,application/xhtml+xml,*/*;q=0.6",
                        )
                        for item in batch
                    ],
                    return_exceptions=True,
                )
                for current_url, result in zip(batch, results):
                    if isinstance(result, Exception):
                        errors.append(f"{current_url}: {result}")
                        continue
                    if not result:
                        continue
                    if "text/html" not in result.content_type and "application/xhtml" not in result.content_type:
                        continue
                    page = self._parse_page(result.text, result.url)
                    normalized_result_url = self._normalize_internal_url(result.url, origin, result.url) or current_url
                    pages[normalized_result_url] = page
                    for link in page.get("links", []):
                        enqueue(link)

        limit_reached = bool(queue) or len(pages) >= self.max_pages
        ordered_pages = sorted(
            pages.values(),
            key=lambda item: (0 if item.get("url") == start_normalized else 1, item.get("path") or item.get("url")),
        )
        return {
            "version": CACHE_VERSION,
            "url": start_url,
            "origin": origin,
            "captured_at": int(time.time()),
            "pages": ordered_pages,
            "limit": self.max_pages,
            "limit_reached": limit_reached,
            "sitemap_pages": len(sitemap_urls),
            "sitemap_page_urls": sitemap_urls[:300],
            "sitemap_sources": sitemap_sources,
            "errors": errors[:5],
        }

    async def _fetch_text(self, client: httpx.AsyncClient, url: str, accept: str) -> FetchResult | None:
        try:
            response = await client.get(url, headers={"Accept": accept})
            if response.status_code >= 400:
                return None
            content_type = response.headers.get("content-type", "").split(";")[0].lower()
            return FetchResult(str(response.url), content_type, response.text)
        except Exception as exc:
            logger.debug("Site structure fetch failed for %s: %s", url, exc)
            return None

    def _parse_page(self, html: str, url: str) -> dict:
        soup = BeautifulSoup(html, "html.parser")
        for tag in soup(["script", "style", "noscript", "svg"]):
            tag.decompose()

        title = soup.title.get_text(" ", strip=True) if soup.title else ""
        description = ""
        desc_tag = soup.find("meta", attrs={"name": re.compile("^description$", re.I)})
        if not desc_tag:
            desc_tag = soup.find("meta", attrs={"property": re.compile("^(og:description|twitter:description)$", re.I)})
        if desc_tag:
            description = str(desc_tag.get("content") or "").strip()

        headings = []
        for tag in soup.find_all(["h1", "h2"], limit=8):
            text = " ".join(tag.get_text(" ", strip=True).split())
            if text:
                headings.append(f"{tag.name.upper()}: {text}")

        links = []
        for anchor in soup.find_all("a", href=True):
            links.append(urljoin(url, str(anchor.get("href") or "")))

        parsed = urlparse(url)
        path = parsed.path or "/"
        if parsed.query:
            path = f"{path}?{parsed.query}"

        return {
            "url": url,
            "path": path,
            "title": title,
            "description": description,
            "headings": headings[:8],
            "links": links,
        }

    async def _discover_sitemap_urls(self, client: httpx.AsyncClient, origin: str) -> tuple[list[str], list[str]]:
        sitemap_queue = [
            urljoin(origin, "/sitemap.xml"),
            urljoin(origin, "/sitemap_index.xml"),
            urljoin(origin, "/wp-sitemap.xml"),
        ]
        seen_sitemaps: set[str] = set()
        page_urls: list[str] = []
        seen_pages: set[str] = set()
        sources: list[str] = []

        while sitemap_queue and len(seen_sitemaps) < 20:
            sitemap_url = sitemap_queue.pop(0)
            if sitemap_url in seen_sitemaps:
                continue
            seen_sitemaps.add(sitemap_url)
            result = await self._fetch_text(
                client,
                sitemap_url,
                "application/xml,text/xml,text/html;q=0.8,*/*;q=0.5",
            )
            if not result or not result.text:
                continue
            sources.append(result.url)
            for raw in self._extract_sitemap_locations(result.text):
                loc = html_lib.unescape(raw.strip())
                if self._looks_like_sitemap(loc, origin):
                    child = self._normalize_sitemap_url(loc, origin, result.url)
                    if child and child not in seen_sitemaps and child not in sitemap_queue:
                        sitemap_queue.append(child)
                    continue
                page_url = self._normalize_internal_url(loc, origin, result.url)
                if page_url and page_url not in seen_pages:
                    seen_pages.add(page_url)
                    page_urls.append(page_url)
        return page_urls, sources

    def _extract_sitemap_locations(self, xml_text: str) -> list[str]:
        return re.findall(r"<loc>\s*([^<]+?)\s*</loc>", xml_text, flags=re.I)

    def _extract_sitemap_urls(self, xml_text: str, origin: str) -> list[str]:
        locs = re.findall(r"<loc>\s*([^<]+?)\s*</loc>", xml_text, flags=re.I)
        out: list[str] = []
        seen: set[str] = set()
        for raw in locs:
            url = self._normalize_internal_url(html_lib.unescape(raw.strip()), origin, origin)
            if url and url not in seen:
                seen.add(url)
                out.append(url)
        return out

    def _looks_like_sitemap(self, value: str, origin: str) -> bool:
        parsed = urlparse(urljoin(origin, value))
        path = parsed.path.lower()
        return path.endswith(".xml") and "sitemap" in path

    def _normalize_sitemap_url(self, value: str | None, origin: str, base_url: str) -> str | None:
        if not value:
            return None
        try:
            resolved = urlparse(urljoin(base_url, value.strip()))
        except Exception:
            return None
        if resolved.scheme not in {"http", "https"} or not resolved.netloc:
            return None
        if f"{resolved.scheme}://{resolved.netloc}".lower() != origin.lower():
            return None
        return urlunparse(resolved._replace(fragment="", query=""))

    def _normalize_internal_url(self, value: str | None, origin: str, base_url: str) -> str | None:
        if not value:
            return None
        value = value.strip()
        if not value or value.startswith(("mailto:", "tel:", "javascript:", "data:")):
            return None
        try:
            resolved = urlparse(urljoin(base_url, value))
        except Exception:
            return None
        if resolved.scheme not in {"http", "https"} or not resolved.netloc:
            return None
        if f"{resolved.scheme}://{resolved.netloc}".lower() != origin.lower():
            return None
        path = resolved.path or "/"
        if any(path.lower().endswith(ext) for ext in _ASSET_EXTENSIONS):
            return None
        normalized = resolved._replace(fragment="", query="", path=path)
        text = urlunparse(normalized)
        if text.endswith("/") and path != "/":
            text = text.rstrip("/")
        return text

    def _format_context(self, data: dict) -> str:
        pages = data.get("pages") or []
        sitemap_pages = int(data.get("sitemap_pages") or 0)
        discovered_pages = len(pages)
        answer_count = max(sitemap_pages, discovered_pages)
        if sitemap_pages and discovered_pages and sitemap_pages != discovered_pages:
            count_source = "sitemap plus internal crawl"
        else:
            count_source = "sitemap" if sitemap_pages else "crawl"
        lines = [
            "## Site Structure (same-origin crawl)",
            "Use this section as evidence for questions about page count, sitemap, internal pages, and website structure.",
            "Page-count answer rules:",
            "- Never estimate, extrapolate, or say 'approximately' for page counts.",
            f"- If asked how many pages the website has, answer with this exact discovered/listed count: {answer_count}.",
            "- Do not call this a guaranteed total of the whole website; say it is what Gyrus found/listed.",
            f"- Count source: {count_source}. If source includes sitemap, say the sitemap lists same-origin page URLs.",
            "- If the crawl limit was reached and no sitemap count exists, say 'at least' the discovered count.",
            f"Origin: {data.get('origin') or ''}",
            f"Exact discovered/listed page count to report: {answer_count}",
            f"Discovered internal HTML pages by crawl: {discovered_pages}",
            f"Same-origin page URLs listed in sitemap(s): {sitemap_pages}",
            f"Crawl limit: {data.get('limit', self.max_pages)}",
            f"Limit reached: {'yes' if data.get('limit_reached') else 'no'}",
        ]
        if data.get("sitemap_sources"):
            lines.append("Sitemap sources checked: " + ", ".join(data.get("sitemap_sources", [])[:6]))
        if data.get("errors") and not pages:
            lines.append("Crawler notes: " + " | ".join(data.get("errors", [])[:3]))
        if data.get("limit_reached") and not sitemap_pages:
            lines.append("When answering page-count questions, say 'at least' this number because the crawl limit was reached.")

        lines.append("\nPages:")
        for page in pages[: self.max_pages]:
            title = page.get("title") or "(no title)"
            path = page.get("path") or page.get("url") or ""
            description = page.get("description") or ""
            lines.append(f"- {path} — {title}")
            if description:
                lines.append(f"  Description: {description[:220]}")
            for heading in (page.get("headings") or [])[:3]:
                lines.append(f"  {heading[:220]}")
        return "\n".join(lines)

    def _format_page_count_answer(self, data: dict, *, language: str | None = None) -> str:
        pages = data.get("pages") or []
        sitemap_pages = int(data.get("sitemap_pages") or 0)
        discovered_pages = len(pages)
        count = max(sitemap_pages, discovered_pages)
        limit_reached = bool(data.get("limit_reached"))
        sitemap_sources = data.get("sitemap_sources") or []

        source = "sitemap" if sitemap_pages else "crawl"
        if sitemap_pages and discovered_pages and sitemap_pages != discovered_pages:
            source = "sitemap_and_crawl"

        if language == "de":
            if count == 0:
                return (
                    "Ich konnte keine internen HTML-Seiten für diese Domain finden. "
                    "Das kann passieren, wenn die Seite Crawling blockiert, keine Sitemap anbietet "
                    "oder interne Links erst per JavaScript nachlädt."
                )

            if source == "sitemap":
                first = f"Die Sitemap listet {count} interne Seiten/URLs für diese Domain."
            elif source == "sitemap_and_crawl":
                first = (
                    f"Gyrus hat {count} interne Seiten/URLs gefunden: "
                    f"{sitemap_pages} in der Sitemap und {discovered_pages} per internem Crawl."
                )
            elif limit_reached:
                first = f"Gyrus hat mindestens {count} interne HTML-Seiten gefunden."
            else:
                first = f"Gyrus hat {count} interne HTML-Seiten gefunden."

            lines = [
                first,
                "Das ist keine LLM-Schätzung, sondern das aktuelle Ergebnis aus Sitemap/interner Link-Erkennung. "
                "Nicht verlinkte oder absichtlich versteckte Seiten können trotzdem fehlen.",
            ]
            if sitemap_sources:
                lines.append("Quelle: " + ", ".join(sitemap_sources[:3]))
            page_lines = self._page_list_lines(data, limit=20)
            if page_lines:
                lines.append("\nGefundene Seiten:")
                lines.extend(page_lines)
            return "\n".join(lines)

        if count == 0:
            return (
                "I could not find internal HTML pages for this domain. This can happen if crawling is blocked, "
                "no sitemap is available, or internal links are loaded only through JavaScript."
            )
        if source == "sitemap":
            first = f"The sitemap lists {count} internal pages/URLs for this domain."
        elif source == "sitemap_and_crawl":
            first = (
                f"Gyrus found {count} internal pages/URLs: "
                f"{sitemap_pages} in the sitemap and {discovered_pages} through internal crawling."
            )
        elif limit_reached:
            first = f"Gyrus found at least {count} internal HTML pages."
        else:
            first = f"Gyrus found {count} internal HTML pages."
        lines = [
            first,
            "This is not an LLM estimate; it is the current sitemap/internal-link discovery result. "
            "Unlinked or intentionally hidden pages can still be missing.",
        ]
        if sitemap_sources:
            lines.append("Source: " + ", ".join(sitemap_sources[:3]))
        page_lines = self._page_list_lines(data, limit=20)
        if page_lines:
            lines.append("\nFound pages:")
            lines.extend(page_lines)
        return "\n".join(lines)

    def _page_list_lines(self, data: dict, *, limit: int = 20) -> list[str]:
        pages = data.get("pages") or []
        page_by_url = {page.get("url"): page for page in pages if page.get("url")}
        sitemap_urls = data.get("sitemap_page_urls") or []
        if sitemap_urls:
            urls = sitemap_urls[:limit]
            lines = []
            for idx, url in enumerate(urls, start=1):
                page = page_by_url.get(url) or {}
                title = page.get("title") or self._path_label(url)
                lines.append(f"{idx}. {title} ({self._path_label(url)})")
            return lines

        lines = []
        for idx, page in enumerate(pages[:limit], start=1):
            title = page.get("title") or self._path_label(page.get("url") or page.get("path") or "")
            path = page.get("path") or self._path_label(page.get("url") or "")
            lines.append(f"{idx}. {title} ({path})")
        return lines

    def _path_label(self, url_or_path: str) -> str:
        if not url_or_path:
            return "/"
        parsed = urlparse(url_or_path)
        if parsed.scheme and parsed.netloc:
            path = parsed.path or "/"
        else:
            path = url_or_path
        return path.rstrip("/") if path != "/" else "/"

    def _cache_path(self, bookmark_id: str, url: str) -> Path:
        digest = hashlib.sha1(url.encode("utf-8")).hexdigest()[:12]
        return self.cache_dir / f"{bookmark_id}-{digest}.json"

    def _read_cache(self, bookmark_id: str, url: str) -> dict | None:
        path = self._cache_path(bookmark_id, url)
        try:
            if not path.exists() or time.time() - path.stat().st_mtime > self.cache_ttl_seconds:
                return None
            data = json.loads(path.read_text(encoding="utf-8"))
            if data.get("version") != CACHE_VERSION:
                return None
            return data
        except Exception:
            return None

    def _write_cache(self, bookmark_id: str, url: str, data: dict) -> None:
        try:
            self.cache_dir.mkdir(parents=True, exist_ok=True)
            self._cache_path(bookmark_id, url).write_text(
                json.dumps(data, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
        except Exception as exc:
            logger.debug("Failed to write site structure cache: %s", exc)


site_structure_service = SiteStructureService()
