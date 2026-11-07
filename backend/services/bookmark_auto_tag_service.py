"""Evidence-checked AI tagging of a single bookmark.

The model must quote the source for every tag it proposes; suggestions without
evidence, broad categories without real support and names outside an existing
tag system are rejected before anything is written. Only previous AI
assignments are replaced — manual tags are user-owned.
"""
import asyncio
import json
import logging
import re

from sqlalchemy.orm import Session

from models.tag import Tag, BookmarkTag
from services.bookmark_derived_data import _safe_brain_sync
from services.tag_colors import next_color as _next_tag_color

logger = logging.getLogger(__name__)

_TAG_NAME_RE = re.compile(r"^[\wäöüÄÖÜß+#.-][\wäöüÄÖÜß +#./-]{0,39}$", re.UNICODE)
_GENERIC_TAG_PATTERNS = {
    "ai": re.compile(
        r"\b(ai|ki|llms?|artificial intelligence|künstliche intelligenz|"
        r"machine learning|deep learning|chatgpt|claude|anthropic|ollama|"
        r"generative ai|agentic|code agents?)\b",
        re.IGNORECASE,
    ),
    "software": re.compile(
        r"\b(software|apps?|applications?|programme?|desktop app|web app)\b",
        re.IGNORECASE,
    ),
    "webdevelopment": re.compile(
        r"\b(webentwicklung|web development|frontend|backend|full[ -]stack|"
        r"html|css|javascript|typescript|react|vue|svelte|wordpress|webdesign|"
        r"website builder|web app)\b",
        re.IGNORECASE,
    ),
}
_GENERIC_TAG_ALIASES = {
    "ki": "ai",
    "ai": "ai",
    "software": "software",
    "web": "webdevelopment",
    "webdev": "webdevelopment",
    "webentwicklung": "webdevelopment",
    "web development": "webdevelopment",
}


def _normalized_text(value: str) -> str:
    return re.sub(r"\s+", " ", value.casefold()).strip()


def _clean_tag_name(value: str) -> str | None:
    name = value.strip().strip("`'\"#*[]{}()").casefold()
    name = re.sub(r"\s+", " ", name)
    if not name or not _TAG_NAME_RE.fullmatch(name):
        return None
    return name


def _parse_tag_suggestions(response: str) -> list[tuple[str, str]]:
    """Parse evidence-backed JSON, with a conservative legacy fallback."""
    cleaned = response.strip()
    if cleaned.startswith("```"):
        cleaned = re.sub(r"^```(?:json)?\s*", "", cleaned, flags=re.IGNORECASE)
        cleaned = re.sub(r"\s*```$", "", cleaned)

    items: list[tuple[str, str]] = []
    start, end = cleaned.find("{"), cleaned.rfind("}")
    if start != -1 and end > start:
        try:
            payload = json.loads(cleaned[start:end + 1])
            raw_tags = payload.get("tags", []) if isinstance(payload, dict) else []
            for item in raw_tags:
                if not isinstance(item, dict):
                    continue
                name = _clean_tag_name(str(item.get("name", "")))
                evidence = str(item.get("evidence", "")).strip()
                if name:
                    items.append((name, evidence))
        except (json.JSONDecodeError, TypeError, ValueError):
            pass

    if items:
        return items

    # Older/smaller models occasionally ignore the JSON instruction. Do not
    # turn prose into tags; only accept short comma-separated names.
    if "\n" in cleaned or len(cleaned) > 160:
        return []
    for raw in cleaned.split(","):
        name = _clean_tag_name(raw)
        if name:
            items.append((name, ""))
    return items


def _generic_tag_supported(name: str, primary_text: str, page_content: str) -> bool:
    category = _GENERIC_TAG_ALIASES.get(name)
    if not category:
        return True
    pattern = _GENERIC_TAG_PATTERNS[category]
    if pattern.search(primary_text):
        return True
    # Extracted pages often contain unrelated navigation, ads, and footer text.
    # One incidental keyword there is not enough to justify a broad category.
    return len(pattern.findall(page_content)) >= 2


def _validated_tag_names(
    response: str,
    context: str,
    primary_text: str,
    page_content: str,
) -> list[str]:
    context_normalized = _normalized_text(context)
    accepted: list[str] = []
    for name, evidence in _parse_tag_suggestions(response):
        evidence_normalized = _normalized_text(evidence)
        has_valid_evidence = (
            len(evidence_normalized) >= 2 and evidence_normalized in context_normalized
        )
        explicitly_named = re.search(
            rf"(?<!\w){re.escape(name)}(?!\w)", context, re.IGNORECASE
        ) is not None
        if not has_valid_evidence and not explicitly_named:
            continue
        if not _generic_tag_supported(name, primary_text, page_content):
            continue
        if name not in accepted:
            accepted.append(name)

    # "software" adds little when the model found a more informative subject.
    if "software" in accepted and any(name != "software" for name in accepted):
        accepted.remove("software")
    return accepted[:3]


def _tagging_prompt(language: str | None, approved_names: list[str]) -> str:
    approved_instruction_de = (
        " Verwende ausschließlich passende Namen aus diesem bestehenden Tag-System: "
        + ", ".join(approved_names[:60]) + ". Erfinde keine neuen Tags."
        if approved_names else ""
    )
    approved_instruction_en = (
        " Use only matching names from this existing tag system: "
        + ", ".join(approved_names[:60]) + ". Do not invent new tags."
        if approved_names else ""
    )

    # The quote requirement makes suggestions auditable and lets us reject a
    # model's unsupported guesses before they ever reach the database.
    if language == "de":
        return (
            "Bestimme das tatsächliche Hauptthema des Inhalts. Vergib 1-3 kurze, "
            "wiederverwendbare Themen-Tags auf Deutsch. Tags beschreiben den Inhalt, "
            "nicht sein Medium: Eine Webseite ist nicht automatisch Webentwicklung, "
            "ein digitales Produkt nicht automatisch Software und moderne Technik nicht automatisch KI. "
            "Verwende solche allgemeinen Tags nur, wenn sie ausdrücklich das Hauptthema sind. "
            "Gib für jedes Tag unter 'evidence' ein kurzes, exakt aus der Quelle kopiertes Zitat an. "
            "Ohne eindeutigen Beleg vergib kein Tag. Antworte ausschließlich als gültiges JSON: "
            "{\"tags\":[{\"name\":\"tag\",\"evidence\":\"exaktes Zitat\"}]}"
            + approved_instruction_de
        )
    return (
        "Identify the actual subject of the content. Assign 1-3 short, reusable topic tags. "
        "Tags describe the content, not its medium: a website is not automatically web development, "
        "a digital product is not automatically software, and modern technology is not automatically AI. "
        "Use those broad tags only when they are explicitly the main subject. "
        "For every tag, put a short exact quote copied from the source in 'evidence'. "
        "If there is no clear evidence, assign no tag. Reply only as valid JSON: "
        "{\"tags\":[{\"name\":\"tag\",\"evidence\":\"exact quote\"}]}"
        + approved_instruction_en
    )


def _load_for_tagging(db: Session, bookmark_id: str):
    """The bookmark plus plain copies of the fields the prompt needs, so the
    event loop never lazy-loads an expired attribute from the database."""
    from fastapi import HTTPException
    from services import bookmark_service

    bm = bookmark_service.get_bookmark(db, bookmark_id)
    if not bm:
        raise HTTPException(status_code=404, detail="Bookmark not found")
    return bm, bm.title, bm.url, bm.description, (bm.scraped_content or "").strip()


def _approved_tag_names(db: Session) -> list[str]:
    return [tag.name for tag in db.query(Tag).order_by(Tag.name).all()]


def _apply_ai_tags(db: Session, bm, suggested: list[str]):
    from services.brain_sync_service import brain_sync_service

    # Replace only previous AI assignments. Manual tags are user-owned and must
    # survive every automatic run.
    db.query(BookmarkTag).filter(
        BookmarkTag.bookmark_id == bm.id,
        BookmarkTag.source == "ai",
    ).delete(synchronize_session=False)
    preserved_tag_ids = {
        row.tag_id
        for row in db.query(BookmarkTag).filter(
            BookmarkTag.bookmark_id == bm.id,
            BookmarkTag.source != "ai",
        ).all()
    }
    existing_tags_query = db.query(Tag).filter(Tag.name.in_(suggested)).all()
    tag_by_name = {t.name: t for t in existing_tags_query}
    for tag_name in suggested:
        tag = tag_by_name.get(tag_name)
        if not tag:
            tag = Tag(name=tag_name, color=_next_tag_color(db), source="ai")
            db.add(tag)
            db.flush()
            tag_by_name[tag_name] = tag
        if tag.id not in preserved_tag_ids:
            db.add(BookmarkTag(bookmark_id=bm.id, tag_id=tag.id, source="ai"))

    db.commit()
    db.expire(bm, ["bookmark_tags"])
    db.refresh(bm)
    _safe_brain_sync(lambda: brain_sync_service.sync_bookmark(db, bm))
    return bm


async def auto_tag_bookmark(db: Session, bookmark_id: str, provider_config: dict | None = None,
                            scrape: bool = True, language: str | None = None):
    """Tag one bookmark with the model. Every database / Brain mirror step
    runs in a worker thread, one at a time, so the shared session is never
    used from two threads at once and the event loop never waits on SQLite."""
    from fastapi import HTTPException
    from services import background, bookmark_service
    from services.llm_service import LLMService
    from services.scraper_service import scraper_service

    bm, title, url, description, content = await asyncio.to_thread(
        _load_for_tagging, db, bookmark_id
    )

    # Reuse Reader/Brain content when it already exists. A batch run only fetches
    # pages that have never been read, so accuracy no longer comes at the cost of
    # downloading every page again.
    if scrape and not content:
        scrape_result = await scraper_service.extract_content(url)
        content = (scrape_result.get("content", "") or "").strip()
        if content:
            await asyncio.to_thread(bookmark_service.store_scraped_content, db, bookmark_id, content)
            background.schedule(bookmark_service.index_bookmark_embedding(bookmark_id, content))

    metadata = (
        f"Title: {title}\n"
        f"URL: {url}\n"
        f"Description: {description or ''}"
    )
    context = metadata + (f"\n\nPage content:\n{content[:10_000]}" if content else "")
    primary_text = f"{title}\n{description or ''}"
    approved_names = await asyncio.to_thread(_approved_tag_names, db)
    prompt = _tagging_prompt(language, approved_names)

    try:
        response = await LLMService.ask_llm(
            prompt=prompt,
            context=context,
            provider_config=provider_config or {"provider": "ollama", "model": "llama3"},
            # Tagging is a short, mechanical task. Disable the reasoning phase
            # (qwen3/deepseek-r1 otherwise spend ~25s "thinking" per bookmark for
            # the same tags) and cap output to a compact evidence payload.
            think=False,
            options={"num_predict": 192, "temperature": 0},
            language=language,
        )
    except Exception:
        # Provider errors can embed URLs, local paths or response bodies.
        logger.exception("Auto-tagging LLM request failed for bookmark %s", bookmark_id)
        raise HTTPException(500, "The language model request failed. Check the AI settings and try again.")

    suggested = _validated_tag_names(response, context, primary_text, content[:10_000])
    if approved_names:
        from services.taxonomy_service import canonical_tag_key
        existing_by_key = {canonical_tag_key(name): name for name in approved_names}
        suggested = [
            existing_by_key[key]
            for name in suggested
            if (key := canonical_tag_key(name)) in existing_by_key
        ]

    return await asyncio.to_thread(_apply_ai_tags, db, bm, suggested)
