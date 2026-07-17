import json
import logging
import re
from datetime import datetime, timezone, timedelta
from sqlalchemy.orm import Session
from sqlalchemy.exc import IntegrityError
from models.bookmark import Bookmark
from models.collection import Collection
from models.tag import Tag, BookmarkTag
from schemas.bookmark import BookmarkCreate, BookmarkUpdate
from services.brain_sync_service import brain_sync_service
from services.tag_colors import next_color as _next_tag_color

logger = logging.getLogger(__name__)

# How long a bookmark stays recoverable in the Trash before it is purged.
TRASH_RETENTION_DAYS = 30


def _safe_brain_sync(action) -> None:
    """Run a brain-sync action without ever breaking the core DB operation.

    The Markdown brain is a secondary, optional feature. A filesystem hiccup
    (long filename, missing permissions, full disk) must not turn a normal
    save or delete into a 500 — the database is the source of truth.
    """
    try:
        action()
    except Exception as e:
        logger.warning("Brain sync skipped (non-fatal): %s", e)


_SORT_COLUMNS = {
    "created_at": Bookmark.created_at,
    "updated_at": Bookmark.updated_at,
    "title": Bookmark.title,
    "url": Bookmark.url,
}


def get_bookmarks(
    db: Session,
    collection_id: str | None = None,
    tag: str | None = None,
    dead_only: bool = False,
    unread_only: bool = False,
    limit: int = 100,
    offset: int = 0,
    sort_by: str = "created_at",
    order: str = "desc",
) -> list[Bookmark]:
    q = db.query(Bookmark).filter(Bookmark.deleted_at.is_(None))
    if collection_id is not None:
        q = q.filter(Bookmark.collection_id == collection_id)
    if tag:
        q = q.join(BookmarkTag).join(Tag).filter(Tag.name == tag)
    if dead_only:
        q = q.filter(Bookmark.is_dead == True)
    if unread_only:
        q = q.filter(Bookmark.is_read == False)

    if sort_by == "tag":
        # Sort by the bookmark's first tag (alphabetically); untagged go last.
        from sqlalchemy import select, func as _func
        min_tag = (
            select(_func.min(Tag.name))
            .select_from(Tag)
            .join(BookmarkTag, BookmarkTag.tag_id == Tag.id)
            .where(BookmarkTag.bookmark_id == Bookmark.id)
            .correlate(Bookmark)
            .scalar_subquery()
        )
        name_expr = _func.lower(min_tag)
        direction = name_expr.asc() if order == "asc" else name_expr.desc()
        q = q.order_by(min_tag.is_(None), direction)
    elif sort_by == "favicon":
        # Group bookmarks from the same site together. We sort by the URL's host
        # (not favicon_path) because favicons are fetched lazily — a favicon-based
        # sort would scramble as icons load in. The host is always known, so this
        # groups deterministically and immediately. www. is stripped.
        from sqlalchemy import func as _func
        after = _func.substr(Bookmark.url, _func.instr(Bookmark.url, '://') + 3)
        first_slash = _func.instr(after, '/')
        host = _func.lower(_func.substr(
            after, 1, _func.iif(first_slash > 0, first_slash - 1, _func.length(after))))
        host = _func.iif(host.like('www.%'), _func.substr(host, 5), host)
        hdir = host.asc() if order == "asc" else host.desc()
        q = q.order_by(hdir, _func.lower(Bookmark.title))
    else:
        col = _SORT_COLUMNS.get(sort_by, Bookmark.created_at)
        # Case-insensitive sort for text columns
        if sort_by in ("title", "url"):
            from sqlalchemy import func as _func
            col_expr = _func.lower(col)
        else:
            col_expr = col
        q = q.order_by(col_expr.asc() if order == "asc" else col_expr.desc())

    return q.offset(offset).limit(limit).all()


def get_bookmark(db: Session, bookmark_id: str, include_deleted: bool = False) -> Bookmark | None:
    q = db.query(Bookmark).filter(Bookmark.id == bookmark_id)
    if not include_deleted:
        q = q.filter(Bookmark.deleted_at.is_(None))
    return q.first()


def create_bookmark(db: Session, data: BookmarkCreate) -> Bookmark:
    from services.url_utils import normalize_url
    url = normalize_url(data.url)

    # Check for duplicates (against the normalized URL)
    found = db.query(Bookmark).filter(Bookmark.url == url).first()
    if found:
        from fastapi import HTTPException
        raise HTTPException(status_code=409, detail="Bookmark already exists")

    collection_id = data.collection_id

    # Extension / menu-bar quick-add: automatic Inbox assignment
    if data.source in ("extension", "menubar") and not collection_id:
        inbox = db.query(Collection).filter(Collection.name == "Inbox", Collection.parent_id == None).first()
        if not inbox:
            try:
                # Use a separate subtransaction-like approach (flush + catch)
                inbox = Collection(name="Inbox")
                db.add(inbox)
                db.flush()
            except IntegrityError:
                db.rollback()
                # If another request created it in the meantime, fetch it
                inbox = db.query(Collection).filter(Collection.name == "Inbox", Collection.parent_id == None).one()
        collection_id = inbox.id

    bm = Bookmark(
        title=data.title,
        url=url,
        description=data.description,
        notes=data.notes,
        collection_id=collection_id,
        source=data.source,
    )
    db.add(bm)
    db.flush()
    _set_tags(db, bm, data.tag_ids)
    db.commit()
    db.refresh(bm)
    
    # Sync with AI Brain (best-effort — never block the save)
    _safe_brain_sync(lambda: brain_sync_service.sync_bookmark(db, bm))
    _safe_brain_sync(lambda: brain_sync_service.rebuild_index(db))

    return bm


def update_bookmark(db: Session, bm: Bookmark, data: BookmarkUpdate) -> Bookmark:
    # Capture old path to handle renames/moves
    try:
        old_path = brain_sync_service._get_bookmark_file_path(db, bm)
    except Exception:
        old_path = None

    changed = data.model_dump(exclude_unset=True, exclude={"tag_ids"})
    for field, value in changed.items():
        setattr(bm, field, value)
    if data.tag_ids is not None:
        _set_tags(db, bm, data.tag_ids)
    db.commit()
    db.refresh(bm)

    # Sync with AI Brain (best-effort — never block the update)
    _safe_brain_sync(lambda: brain_sync_service.sync_bookmark(db, bm, old_path=old_path))
    _safe_brain_sync(lambda: brain_sync_service.rebuild_index(db))

    # Re-embed when text the vector is built from changed, so semantic search
    # doesn't keep ranking by the old content. Same text selection as reindex:
    # scraped content if present, else title + description.
    if changed.keys() & {"title", "description", "notes", "scraped_content"}:
        text = bm.scraped_content or f"{bm.title or ''} {bm.description or ''}".strip()
        if text:
            from services import background
            background.schedule(index_bookmark_embedding(bm.id, text))

    return bm


def delete_bookmark(db: Session, bm: Bookmark) -> None:
    """Soft-delete: move the bookmark to the Trash. Its AI-Brain markdown file is
    removed so it disappears from the mirror, but the row is kept (recoverable)
    until it is purged."""
    db_session = Session.object_session(bm)
    _safe_brain_sync(lambda: brain_sync_service.delete_bookmark_file(db_session, bm))
    # Remove from vector index so it no longer appears in semantic search.
    try:
        from services import vector_store
        vector_store.delete(bm.id)
    except Exception:
        pass

    bm.deleted_at = datetime.now(timezone.utc)
    db.commit()
    _safe_brain_sync(lambda: brain_sync_service.rebuild_index(db))


def delete_bookmarks(db: Session, ids: list[str]) -> None:
    """Soft-delete multiple bookmarks (move them to the Trash)."""
    # Best-effort: remove the brain markdown files (only for ones not already trashed).
    bms = db.query(Bookmark).filter(
        Bookmark.id.in_(ids), Bookmark.deleted_at.is_(None)
    ).all()
    for bm in bms:
        _safe_brain_sync(lambda: brain_sync_service.delete_bookmark_file(db, bm))
    _drop_vectors([bm.id for bm in bms])

    db.query(Bookmark).filter(
        Bookmark.id.in_(ids), Bookmark.deleted_at.is_(None)
    ).update({Bookmark.deleted_at: datetime.now(timezone.utc)}, synchronize_session=False)
    db.commit()
    _safe_brain_sync(lambda: brain_sync_service.rebuild_index(db))


def _drop_vectors(ids: list[str]) -> None:
    """Best-effort removal of semantic-search vectors for the given bookmarks.
    Trashed/purged bookmarks must not occupy KNN slots or leave orphan rows."""
    if not ids:
        return
    try:
        from services import vector_store
        for bm_id in ids:
            vector_store.delete(bm_id)
    except Exception:
        pass


def get_trashed(db: Session, limit: int = 200, offset: int = 0) -> list[Bookmark]:
    """List bookmarks currently in the Trash, most recently deleted first."""
    return (
        db.query(Bookmark)
        .filter(Bookmark.deleted_at.is_not(None))
        .order_by(Bookmark.deleted_at.desc())
        .offset(offset)
        .limit(limit)
        .all()
    )


def count_trashed(db: Session) -> int:
    return db.query(Bookmark).filter(Bookmark.deleted_at.is_not(None)).count()


def restore_bookmarks(db: Session, ids: list[str]) -> int:
    """Bring bookmarks back from the Trash and recreate their brain files."""
    bms = db.query(Bookmark).filter(
        Bookmark.id.in_(ids), Bookmark.deleted_at.is_not(None)
    ).all()
    for bm in bms:
        bm.deleted_at = None
    db.commit()
    for bm in bms:
        _safe_brain_sync(lambda: brain_sync_service.sync_bookmark(db, bm))
        # The vector was dropped when the bookmark was trashed — rebuild it
        # so the restored bookmark is findable by semantic search again.
        if bm.scraped_content:
            from services import background
            background.schedule(index_bookmark_embedding(bm.id, bm.scraped_content))
    _safe_brain_sync(lambda: brain_sync_service.rebuild_index(db))
    return len(bms)


def purge_bookmarks(db: Session, ids: list[str] | None = None) -> int:
    """Permanently delete trashed bookmarks. ids=None empties the whole Trash.
    Only ever touches rows that are already in the Trash."""
    q = db.query(Bookmark).filter(Bookmark.deleted_at.is_not(None))
    if ids is not None:
        q = q.filter(Bookmark.id.in_(ids))
    # Vectors are normally dropped on trashing, but clean up stragglers so a
    # hard delete never leaves orphan rows in bookmarks_vec.
    _drop_vectors([row.id for row in q.with_entities(Bookmark.id).all()])
    n = q.count()
    q.delete(synchronize_session=False)
    db.commit()
    return n


def purge_expired(db: Session, days: int = TRASH_RETENTION_DAYS) -> int:
    """Hard-delete bookmarks that have sat in the Trash longer than `days`."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    q = db.query(Bookmark).filter(
        Bookmark.deleted_at.is_not(None), Bookmark.deleted_at < cutoff
    )
    n = q.count()
    if n:
        _drop_vectors([row.id for row in q.with_entities(Bookmark.id).all()])
        q.delete(synchronize_session=False)
        db.commit()
    return n


def store_scraped_content(db: Session, bookmark_id: str, content: str) -> None:
    """Cache extracted page text on the bookmark so full-text search can match
    the article body. Best-effort — never let an indexing write break the
    caller's main flow (reader, chat, auto-tag)."""
    if not content:
        return
    try:
        bm = db.query(Bookmark).filter(Bookmark.id == bookmark_id).first()
        if bm is not None and bm.scraped_content != content:
            bm.scraped_content = content
            db.commit()
    except Exception as e:
        logger.warning("storing scraped content failed: %s", e)
        db.rollback()


async def index_bookmark_embedding(bookmark_id: str, text: str) -> None:
    """Compute and store an embedding for a bookmark (best-effort, never blocks
    the caller).  Called after page content is scraped so semantic search can
    find this bookmark by meaning, not just keywords."""
    if not text or not text.strip():
        return
    try:
        from services.embedding_service import get_embedding, EmbeddingUnavailableError
        from services import vector_store
        vec = await get_embedding(text)
        vector_store.upsert(bookmark_id, vec)
    except Exception as e:
        # Ollama down, model missing, DB write error — none of these should
        # affect the caller; semantic search simply won't find this bookmark.
        logger.debug("embedding indexing skipped for %s: %s", bookmark_id, e)


def _set_tags(db: Session, bm: Bookmark, tag_ids: list[str]) -> None:
    db.query(BookmarkTag).filter(BookmarkTag.bookmark_id == bm.id).delete()
    for tag_id in tag_ids:
        db.add(BookmarkTag(bookmark_id=bm.id, tag_id=tag_id, source="manual"))


def get_bookmark_tags(bm: Bookmark) -> list[Tag]:
    return [bt.tag for bt in bm.bookmark_tags]


def update_bookmark_metadata(db: Session, bm: Bookmark, meta: dict) -> Bookmark:
    """Apply metadata fetched from metadata_service to the bookmark."""
    if meta.get("description") and not bm.description:
        bm.description = meta["description"]
    if meta.get("og_image_url"):
        bm.og_image_url = meta["og_image_url"]
    if meta.get("og_image_path"):
        bm.og_image_path = meta["og_image_path"]
    if meta.get("favicon_path"):
        bm.favicon_path = meta["favicon_path"]
    db.commit()
    db.refresh(bm)
    
    # Sync with AI Brain
    _safe_brain_sync(lambda: brain_sync_service.sync_bookmark(db, bm))
    return bm


def add_note(db: Session, bookmark_id: str, content: str, source: str = "manual"):
    from models.bookmark import BookmarkNote
    note = BookmarkNote(
        bookmark_id=bookmark_id,
        content=content,
        source=source
    )
    db.add(note)
    db.commit()
    db.refresh(note)
    return note


def delete_note(db: Session, bookmark_id: str, note_id: str):
    from models.bookmark import BookmarkNote
    note = db.query(BookmarkNote).filter(
        BookmarkNote.id == note_id, 
        BookmarkNote.bookmark_id == bookmark_id
    ).first()
    if note:
        db.delete(note)
        db.commit()
        return True
    return False


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

_FAST_TAG_RULES: list[tuple[str, tuple[str, ...]]] = [
    ("ki", (
        " ai ", " ki ", "llm", "chatgpt", "claude", "anthropic", "ollama",
        "agentic", "code agent", "machine learning", "künstliche intelligenz",
    )),
    ("softwareentwicklung", (
        "coding", "developer", "development", "entwickl", "programming",
        "wordpress", "mcp", "swift", "python", "typescript", "javascript",
        "native-macos", "source code", "software architecture",
    )),
    ("webdesign", (
        "webdesign", "web design", "frontend", "css", "layout", "typografie",
        "typography", "design skill", "website", "figma", "hallmark",
    )),
    ("creative coding", (
        "creative coding", "realtime-vfx", "real-time vfx", "metal node",
        "shader", "generative art", "visual ideas",
    )),
    ("videobearbeitung", (
        "video editing", "videobearbeitung", "video editor",
        "timeline", "schnittprogramm", "video schneiden",
    )),
    ("musikproduktion", (
        "daw", "audio", "music production", "musikproduktion",
        "plugin", "synthesizer",
    )),
    ("coworking", (
        "coworking", "co-working", "virtual office", "virtuelles büro",
        "besprechungsräume", "büros", "office service",
    )),
    ("immobilien", (
        "immobilien", "wohnung", "haus ",
        "bungalow", "m²", "mieten", "real estate",
    )),
    ("bau", (
        "baustoff", "bau ", "reparieren", "sanierung",
    )),
    ("lesen", (
        "read more books", "flashcards", "book", "bücher", "lesen",
    )),
    ("gesundheit", (
        "health", "gesundheit", "mental health", "medizin", "fitness",
    )),
    ("social media", (
        "social media", "posting", "facebook", "instagram", "tiktok",
    )),
    ("detektei", (
        "detektei", "ermittlung", "wirtschaftskriminalität", "privatdetektiv",
    )),
    ("finanzen", (
        "finance", "finanzen", "bank", "crypto", "stock", "fintech",
    )),
    ("open source", (
        "open source", "open-source", "github.com",
    )),
]


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


def _fast_tag_names(bm: Bookmark, content: str = "", limit: int = 3) -> list[str]:
    """Cheap local first pass for imports.

    This deliberately trades nuance for speed: no LLM, no global taxonomy, just
    broad user-facing buckets based on title, URL, description, and cached reader
    text. The slower review workflow can still refine the system later.
    """
    text_haystack = _normalized_text(
        "\n".join(filter(None, [bm.title, bm.description or "", content[:4000]]))
    )
    all_haystack = _normalized_text(
        "\n".join(filter(None, [bm.title, bm.url, bm.description or "", content[:4000]]))
    )
    padded_text = f" {text_haystack} "
    padded_all = f" {all_haystack} "
    scored: list[tuple[int, int, str]] = []
    for order, (tag_name, needles) in enumerate(_FAST_TAG_RULES):
        score = 0
        for needle in needles:
            normalized = _normalized_text(needle)
            search_space = padded_all if "." in normalized or "/" in normalized else padded_text
            if not normalized:
                continue
            if normalized.isalpha() and len(normalized) <= 3:
                if re.search(rf"(?<!\w){re.escape(normalized)}(?!\w)", search_space):
                    score += 1
            elif normalized in search_space:
                score += 1
        if score:
            scored.append((score, -order, tag_name))
    scored.sort(reverse=True)

    selected: list[str] = []
    for _, _, tag_name in scored:
        if tag_name not in selected:
            selected.append(tag_name)
        if len(selected) >= limit:
            break
    return selected


def apply_fast_auto_tags(db: Session, bm: Bookmark, content: str = "", limit: int = 3) -> Bookmark:
    suggested = _fast_tag_names(bm, content=content, limit=limit)
    if not suggested:
        return bm

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
    for tag_name in suggested:
        tag = db.query(Tag).filter(Tag.name == tag_name).first()
        if not tag:
            tag = Tag(name=tag_name, color=_next_tag_color(db), source="ai")
            db.add(tag)
            db.flush()
        if tag.id not in preserved_tag_ids:
            db.add(BookmarkTag(bookmark_id=bm.id, tag_id=tag.id, source="ai"))
    db.commit()
    db.expire(bm, ["bookmark_tags"])
    db.refresh(bm)
    _safe_brain_sync(lambda: brain_sync_service.sync_bookmark(db, bm))
    return bm


async def auto_tag_bookmark(db: Session, bookmark_id: str, provider_config: dict | None = None,
                            scrape: bool = True, language: str | None = None) -> Bookmark:
    from services.scraper_service import scraper_service
    from services.llm_service import LLMService
    from fastapi import HTTPException

    bm = get_bookmark(db, bookmark_id)
    if not bm:
        raise HTTPException(status_code=404, detail="Bookmark not found")

    # Reuse Reader/Brain content when it already exists. A batch run only fetches
    # pages that have never been read, so accuracy no longer comes at the cost of
    # downloading every page again.
    content = (bm.scraped_content or "").strip()
    if scrape and not content:
        scrape_result = await scraper_service.extract_content(bm.url)
        content = (scrape_result.get("content", "") or "").strip()
        if content:
            store_scraped_content(db, bookmark_id, content)
            from services import background
            background.schedule(index_bookmark_embedding(bookmark_id, content))

    metadata = (
        f"Title: {bm.title}\n"
        f"URL: {bm.url}\n"
        f"Description: {bm.description or ''}"
    )
    context = metadata + (f"\n\nPage content:\n{content[:10_000]}" if content else "")
    primary_text = f"{bm.title}\n{bm.description or ''}"
    existing_tags = db.query(Tag).order_by(Tag.name).all()
    approved_names = [tag.name for tag in existing_tags]
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
        prompt = (
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
    else:
        prompt = (
            "Identify the actual subject of the content. Assign 1-3 short, reusable topic tags. "
            "Tags describe the content, not its medium: a website is not automatically web development, "
            "a digital product is not automatically software, and modern technology is not automatically AI. "
            "Use those broad tags only when they are explicitly the main subject. "
            "For every tag, put a short exact quote copied from the source in 'evidence'. "
            "If there is no clear evidence, assign no tag. Reply only as valid JSON: "
            "{\"tags\":[{\"name\":\"tag\",\"evidence\":\"exact quote\"}]}"
            + approved_instruction_en
        )
    
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
    except Exception as e:
        raise HTTPException(500, f"LLM Error: {str(e)}")

    suggested = _validated_tag_names(response, context, primary_text, content[:10_000])
    if existing_tags:
        from services.taxonomy_service import canonical_tag_key
        existing_by_key = {canonical_tag_key(tag.name): tag.name for tag in existing_tags}
        suggested = [
            existing_by_key[key]
            for name in suggested
            if (key := canonical_tag_key(name)) in existing_by_key
        ]

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
    for tag_name in suggested:
        tag = db.query(Tag).filter(Tag.name == tag_name).first()
        if not tag:
            tag = Tag(name=tag_name, color=_next_tag_color(db), source="ai")
            db.add(tag)
            db.flush()
        if tag.id not in preserved_tag_ids:
            db.add(BookmarkTag(bookmark_id=bm.id, tag_id=tag.id, source="ai"))

    db.commit()
    db.expire(bm, ["bookmark_tags"])
    db.refresh(bm)
    return bm
