import hashlib
import io
import logging
from urllib.parse import urljoin, urlparse

import httpx
from PIL import Image

from database import DATA_DIR

logger = logging.getLogger(__name__)

FAVICONS_DIR = DATA_DIR / "favicons"
OG_IMAGES_DIR = DATA_DIR / "og_images"
TIMEOUT = httpx.Timeout(10.0)
OG_MAX_WIDTH = 600

# A browser-like User-Agent applied to ALL requests (page, favicon, OG image).
# Some sites (e.g. Wikipedia) serve favicons differently — or block them — for
# a generic bot UA, which is why favicons were silently missing.
_UA_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    ),
    "Accept-Language": "en-US,en;q=0.9",
}


async def fetch_metadata(url: str) -> dict:
    result = {"og_image_url": None, "og_image_path": None, "description": None, "favicon_path": None}
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT, follow_redirects=True, headers=_UA_HEADERS) as client:
            from bs4 import BeautifulSoup

            # Fetch and parse the page — but a failure here (e.g. a 403 from a
            # bot-protected site) must NOT abort the favicon, which often lives
            # at a well-known path that's still reachable.
            soup = None
            page_url = url
            try:
                resp = await client.get(url)
                resp.raise_for_status()
                # Final URL after redirects — e.g. GitHub Pages project sites
                # redirect "/project" to "/project/", which is what relative
                # favicon hrefs and well-known paths must resolve against.
                page_url = str(resp.url)
                soup = BeautifulSoup(resp.text, "html.parser")
            except Exception as e:
                logger.info("page fetch failed for %s (will still try favicon): %s", url, e)

            if soup is not None:
                og_image = soup.find("meta", property="og:image")
                if og_image and og_image.get("content"):
                    result["og_image_url"] = og_image["content"]

                og_desc = soup.find("meta", property="og:description")
                meta_desc = soup.find("meta", attrs={"name": "description"})
                if og_desc and og_desc.get("content"):
                    result["description"] = og_desc["content"][:500]
                elif meta_desc and meta_desc.get("content"):
                    result["description"] = meta_desc["content"][:500]

            result["favicon_path"] = await _fetch_favicon(page_url, soup, client)
            if result["og_image_url"]:
                result["og_image_path"] = await _fetch_og_image(result["og_image_url"], url, client)

    except Exception as e:
        logger.warning("metadata fetch failed for %s: %s", url, e)

    return result


# Image content types the app can render via NSImage — including SVG, which
# many modern sites (e.g. agenturincognito.de) use as their only favicon.
_IMAGE_EXT_BY_CONTENT_TYPE = {
    "image/png": ".png",
    "image/x-icon": ".ico",
    "image/vnd.microsoft.icon": ".ico",
    "image/jpeg": ".jpg",
    "image/jpg": ".jpg",
    "image/gif": ".gif",
    "image/webp": ".webp",
    "image/svg+xml": ".svg",
}


def _favicon_candidates(soup, page_url: str) -> list[str]:
    """Build an ordered list of favicon URLs to try, best first.

    Prefers icons the page explicitly declares (and raster formats over SVG),
    then falls back to conventional well-known paths. `soup` may be None when
    the page itself was blocked (e.g. 403) — the well-known paths often still
    work in that case.

    Declared hrefs and the page-relative well-known paths resolve against the
    full page URL (not just the domain root), so project sites served under a
    sub-path — e.g. `user.github.io/project/`, whose favicon lives at
    `/project/favicon.ico` — are found instead of 404ing at the domain root.
    """
    parsed = urlparse(page_url)
    domain_root = f"{parsed.scheme}://{parsed.netloc}"

    scored: list[tuple[int, str]] = []
    for link in (soup.find_all("link") if soup is not None else []):
        rel = " ".join(link.get("rel", []) or []).lower()
        if "icon" not in rel:
            continue
        href = link.get("href")
        if not href:
            continue
        abs_url = urljoin(page_url, href)
        type_attr = (link.get("type") or "").lower()
        is_svg = "svg" in type_attr or abs_url.lower().split("?")[0].endswith(".svg")
        # apple-touch-icon is reliably a decently sized PNG → best raster choice.
        if "apple-touch-icon" in rel:
            priority = 5 if is_svg else 0
        else:
            priority = 4 if is_svg else 1
        scored.append((priority, abs_url))

    # Conventional well-known locations at the domain root (works even when the
    # page is blocked and we have no declared <link> tags).
    scored.append((2, urljoin(domain_root, "/apple-touch-icon.png")))
    scored.append((3, urljoin(domain_root, "/favicon.ico")))
    scored.append((3, urljoin(domain_root, "/favicon.png")))
    scored.append((4, urljoin(domain_root, "/favicon.svg")))

    # ...and relative to the page directory, for sub-path project sites.
    if parsed.path not in ("", "/"):
        scored.append((2, urljoin(page_url, "apple-touch-icon.png")))
        scored.append((3, urljoin(page_url, "favicon.ico")))
        scored.append((3, urljoin(page_url, "favicon.png")))
        scored.append((4, urljoin(page_url, "favicon.svg")))

    scored.sort(key=lambda x: x[0])
    seen: set[str] = set()
    ordered: list[str] = []
    for _, candidate in scored:
        if candidate not in seen:
            seen.add(candidate)
            ordered.append(candidate)
    return ordered


def _image_extension(content: bytes, content_type: str) -> str | None:
    """Return a file extension if the bytes look like a renderable image.

    Trusts the content type when it names a known format, otherwise sniffs the
    content. Returns None for the soft-404 HTML pages many sites serve at
    /favicon.ico.
    """
    ct = content_type.split(";")[0].strip().lower()
    if ct in _IMAGE_EXT_BY_CONTENT_TYPE:
        return _IMAGE_EXT_BY_CONTENT_TYPE[ct]
    # Detect SVG by content (some servers send it as text/xml or text/plain),
    # but only when it actually starts as SVG — not an HTML page with svg inside.
    head = content[:512].lstrip()
    if head.startswith(b"<svg") or (head.startswith(b"<?xml") and b"<svg" in head):
        return ".svg"
    if ct in ("text/html", "application/xml") or ct.startswith("text/"):
        return None
    # Fall back to magic-byte sniffing when the header is missing or generic.
    if content.startswith(b"\x89PNG\r\n\x1a\n"):
        return ".png"
    if content.startswith(b"\x00\x00\x01\x00"):
        return ".ico"
    if content.startswith(b"\xff\xd8\xff"):
        return ".jpg"
    if content.startswith(b"GIF8"):
        return ".gif"
    if content[:4] == b"RIFF" and content[8:12] == b"WEBP":
        return ".webp"
    return None


async def _fetch_favicon(page_url: str, soup, client: httpx.AsyncClient) -> str | None:
    parsed = urlparse(page_url)
    file_hash = hashlib.sha256(parsed.netloc.encode()).hexdigest()[:16]

    for candidate in _favicon_candidates(soup, page_url):
        try:
            resp = await client.get(candidate, timeout=5.0)
            if resp.status_code != 200 or not resp.content:
                continue
            ext = _image_extension(resp.content, resp.headers.get("content-type", ""))
            if ext is None:
                continue  # not a renderable image (e.g. an HTML 404 page)
            filename = f"{file_hash}{ext}"
            (FAVICONS_DIR / filename).write_bytes(resp.content)
            return filename
        except Exception as e:
            logger.debug("favicon candidate failed (%s): %s", candidate, e)
            continue
    return None


async def _fetch_og_image(image_url: str, page_url: str, client: httpx.AsyncClient) -> str | None:
    """Download the OG image, downscale it, and store a local JPEG.

    Caching locally means the app reads previews from disk instead of
    re-fetching full-size social-share images from remote servers on
    every scroll.
    """
    try:
        abs_url = urljoin(page_url, image_url)
        resp = await client.get(abs_url, timeout=10.0)
        if resp.status_code != 200 or not resp.content:
            return None

        img = Image.open(io.BytesIO(resp.content)).convert("RGBA")
        background = Image.new("RGB", img.size, (255, 255, 255))
        background.paste(img, mask=img.split()[3])
        img = background

        if img.width > OG_MAX_WIDTH:
            ratio = OG_MAX_WIDTH / img.width
            # Use Resampling enum for modern PIL compatibility
            resample = getattr(Image, "Resampling", Image).LANCZOS
            img = img.resize((OG_MAX_WIDTH, round(img.height * ratio)), resample)

        file_hash = hashlib.sha256(abs_url.encode()).hexdigest()[:16]
        filename = f"{file_hash}.jpg"
        path = OG_IMAGES_DIR / filename
        img.save(path, "JPEG", quality=82)
        return filename
    except Exception as e:
        logger.debug("og image fetch failed for %s: %s", image_url, e)
    return None
