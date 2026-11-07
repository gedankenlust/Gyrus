"""Page context for AI Brain chat and summaries.

Builds the text the model answers from: durable Reader text, else a mirror
cache tied to the bookmark's exact URL, else a fresh scrape; plus site
structure and visual snapshot sections when the question is about them.

Database and file work runs in worker threads, one call at a time on the
caller's session; the event loop only awaits the network (scrape, crawl).
"""
import asyncio
import logging
from urllib.parse import quote

from sqlalchemy.orm import Session

from services.brain_sync_service import brain_sync_service
from services import visual_snapshot_service
from services.site_structure_service import site_structure_service

logger = logging.getLogger(__name__)

SCRAPED_HEADER = "## Content (Scraped)"
# Bump this when the scraper improves, so cached content from older versions is
# re-scraped once instead of being served stale forever.
SCRAPE_MARKER = "<!-- gyrus-scrape v4 -->"
MAX_CONTEXT_CHARS = 12000
MAX_SNAPSHOT_CONTEXT_CHARS = 5200


def _scrape_source_marker(url: str) -> str:
    return f"<!-- gyrus-source-url: {quote(url, safe='')} -->"


def _persist_scraped_content(file_path, content: str, source_url: str) -> None:
    """Write freshly scraped content into the bookmark's markdown file,
    replacing any previous scraped section while preserving the chat history
    that follows it."""
    if file_path is None or not brain_sync_service.is_enabled or not brain_sync_service._owns(file_path):
        return
    try:
        text = file_path.read_text(encoding="utf-8")
    except Exception:
        return
    section = f"{SCRAPED_HEADER}\n{SCRAPE_MARKER}\n{_scrape_source_marker(source_url)}\n{content}\n"
    if SCRAPED_HEADER in text:
        before, rest = text.split(SCRAPED_HEADER, 1)
        # Keep any following sections (e.g. "## Chat Interaction ...").
        idx = rest.find("\n## ")
        after = rest[idx:] if idx != -1 else ""
        new_text = before.rstrip() + "\n\n" + section + after
    else:
        new_text = text.rstrip() + "\n\n" + section
    try:
        file_path.write_text(new_text, encoding="utf-8")
    except Exception as e:
        logger.warning(f"Failed to persist scraped content: {e}")


def _should_include_visual_context(prompt: str | None) -> bool:
    text = (prompt or "").lower()
    terms = (
        "design", "layout", "farbe", "farben", "color", "colour", "font",
        "typografie", "typography", "ui", "ux", "viewport", "responsive",
        "desktop", "tablet", "mobile", "komponent", "component", "button",
        "navigation", "spacing", "abstand", "css", "style", "visuell",
        "visual", "accessibility", "barriere", "a11y", "seo", "asset",
    )
    return any(term in text for term in terms)


def _visual_snapshot_context(bookmark_id: str) -> str:
    snapshot = visual_snapshot_service.read_snapshot(bookmark_id)
    if not snapshot:
        return ""

    lines: list[str] = [
        "## Visual Snapshot (Rendered page / computed styles)",
        "This section is captured from a headless browser and may be used as direct evidence for visual design questions.",
    ]
    if snapshot.get("captured_at"):
        lines.append(f"Captured at: {snapshot.get('captured_at')}")

    for viewport in snapshot.get("viewports", [])[:3]:
        name = viewport.get("name", "viewport")
        width = viewport.get("width", "")
        height = viewport.get("height", "")
        lines.append(f"\n### Viewport: {name} ({width}x{height})")

        page_title = viewport.get("page_title")
        if page_title:
            lines.append(f"Page title: {page_title}")
        meta_description = viewport.get("meta_description")
        if meta_description:
            lines.append(f"Meta description: {meta_description[:500]}")

        colors = []
        for color in (viewport.get("dominant_colors") or []) + (viewport.get("observed_colors") or []):
            if color and color not in colors:
                colors.append(color)
        if colors:
            lines.append("Colors: " + ", ".join(colors[:24]))

        fonts = viewport.get("observed_fonts") or []
        if fonts:
            lines.append("Fonts: " + " | ".join(fonts[:8]))

        structure = viewport.get("structure") or {}
        if structure:
            lines.append(
                "Structure: "
                f"links={structure.get('links', 0)}, "
                f"buttons={structure.get('buttons', 0)}, "
                f"images={structure.get('images', 0)}, "
                f"svgs={structure.get('svgs', 0)}, "
                f"forms={structure.get('forms', 0)}"
            )
            for heading in (structure.get("h1") or [])[:2]:
                lines.append(f"H1: {heading}")
            for heading in (structure.get("h2") or [])[:3]:
                lines.append(f"H2: {heading}")

        issues = viewport.get("responsive_issues") or []
        if issues:
            counts = {
                severity: sum(1 for issue in issues if issue.get("severity") == severity)
                for severity in ("high", "medium", "low")
            }
            lines.append(
                "Responsive findings: "
                f"high={counts['high']}, medium={counts['medium']}, low={counts['low']}"
            )
            for issue in issues[:6]:
                lines.append(
                    "- "
                    f"[{issue.get('severity', 'unknown')}] {issue.get('title', '')}: "
                    f"{issue.get('detail', '')} "
                    f"at {issue.get('selector_hint', '')} ({issue.get('metric', '')})"
                )

        lines.append("Computed element samples:")
        for sample in (viewport.get("element_samples") or [])[:4]:
            selector = sample.get("selector_hint") or sample.get("tag") or "element"
            text = (sample.get("text") or "").replace("\n", " ")[:120]
            lines.append(
                "- "
                f"{selector} ({sample.get('tag', '')}) "
                f"{sample.get('width', 0)}x{sample.get('height', 0)} at "
                f"{sample.get('x', 0)},{sample.get('y', 0)}; "
                f"display={sample.get('display', '')}; "
                f"position={sample.get('position', '')}; "
                f"font={sample.get('font_family', '')}; "
                f"size={sample.get('font_size', '')}; "
                f"weight={sample.get('font_weight', '')}; "
                f"color={sample.get('color', '')}; "
                f"background={sample.get('background_color', '')}; "
                f"padding={sample.get('padding', '')}; "
                f"margin={sample.get('margin', '')}; "
                f"radius={sample.get('border_radius', '')}; "
                f"shadow={sample.get('box_shadow', '')}; "
                f"text={text}"
            )

    text = "\n".join(lines)
    if len(text) > MAX_SNAPSHOT_CONTEXT_CHARS:
        text = text[:MAX_SNAPSHOT_CONTEXT_CHARS] + "... [Visual Snapshot Truncated]"
    return text


def _load_context_sources(db: Session, bookmark) -> dict:
    """Refresh the bookmark's mirror file and read the cached context.
    Returns plain values so the event loop never touches the ORM object."""
    file_path = None
    full_text = ""
    if brain_sync_service.is_enabled:
        try:
            file_path = brain_sync_service._get_bookmark_file_path(db, bookmark)
            brain_sync_service.sync_bookmark(db, bookmark)
            if brain_sync_service._owns(file_path, bookmark.id):
                full_text = file_path.read_text(encoding="utf-8")
        except (OSError, ValueError) as exc:
            logger.warning("Brain mirror unavailable: %s", exc)
            file_path = None

    context = (bookmark.scraped_content or "").strip()
    if not context and SCRAPED_HEADER in full_text:
        cached = full_text.split(SCRAPED_HEADER, 1)[1].split("\n## ")[0].strip()
        if SCRAPE_MARKER in cached and _scrape_source_marker(bookmark.url) in cached:
            context = cached.replace(SCRAPE_MARKER, "").replace(_scrape_source_marker(bookmark.url), "").strip()
    return {
        "file_path": file_path,
        "context": context,
        "id": bookmark.id,
        "url": bookmark.url,
        "title": bookmark.title,
        "description": bookmark.description,
    }


def _store_scrape(db: Session, file_path, bookmark_id: str, content: str, url: str) -> None:
    from services import bookmark_service

    _persist_scraped_content(file_path, content, url)
    bookmark_service.store_scraped_content(db, bookmark_id, content)


async def prepare_context(db: Session, bookmark, prompt: str | None = None) -> str:
    """Use durable Reader text, or a mirror cache tied to this exact URL."""
    sources = await asyncio.to_thread(_load_context_sources, db, bookmark)
    context = sources["context"]
    bookmark_id, url = sources["id"], sources["url"]

    needs_scrape = not context
    if needs_scrape:
        from services.scraper_service import scraper_service

        scrape_result = await scraper_service.extract_content(url)
        content = scrape_result.get("content", "")
        if content:
            context = content
            await asyncio.to_thread(
                _store_scrape, db, sources["file_path"], bookmark_id, content, url
            )
            from services import bookmark_service, background
            background.schedule(
                bookmark_service.index_bookmark_embedding(bookmark_id, content)
            )
        elif not context:
            context = f"Title: {sources['title']}\nDescription: {sources['description']}\nURL: {url}"

    context = context.replace(SCRAPE_MARKER, "").strip()
    if len(context) > MAX_CONTEXT_CHARS:
        context = context[:MAX_CONTEXT_CHARS] + "... [Content Truncated]"
    if site_structure_service.should_include_for_prompt(prompt):
        site_context = await site_structure_service.context_for_url(bookmark_id, url)
        if site_context:
            context = f"{context}\n\n{site_context}" if context else site_context
    if _should_include_visual_context(prompt):
        visual_context = await asyncio.to_thread(_visual_snapshot_context, bookmark_id)
        if visual_context:
            context = f"{context}\n\n{visual_context}" if context else visual_context
    return context
