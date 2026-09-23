"""Build a new folder structure with the local model, then move bookmarks into it.

The model first names the folders. It then assigns bookmarks in small batches,
with a rest between batches. Nothing is moved if the model never returns a
structure, or if the run is stopped first. A database backup is written
before the first move. Existing folders are left in place.
"""
from __future__ import annotations

import asyncio
import re
import time
from collections import Counter, defaultdict
from datetime import datetime
from urllib.parse import urlparse

from database import SessionLocal
from models.bookmark import Bookmark
from models.collection import Collection
from services.background_job import BackgroundJob
from services.bookmark_service import move_bookmarks
from services.tagging_pacer import TaggingPacer

MAX_TOPS = 16
MAX_CHILDREN = 4
BATCH_SIZE = 20
NAME_LIMIT = 40
# Long enough for the fans to pull the chip back down after a batch.
REST_SECONDS = 40.0
MIN_SITE_GROUP = 3
# Search pages and shorteners are not a folder. The link does not say what the
# bookmark is about.
GENERIC_SITES = {"google", "bing", "duckduckgo", "yahoo", "t", "bit", "tinyurl", "amp"}
SITE_LABELS = {
    "youtube": "YouTube",
    "twitch": "Twitch",
    "github": "GitHub",
    "wikipedia": "Wikipedia",
    "amazon": "Amazon",
    "reddit": "Reddit",
    "instagram": "Instagram",
    "facebook": "Facebook",
    "vimeo": "Vimeo",
    "soundcloud": "SoundCloud",
    "spotify": "Spotify",
    "stackoverflow": "Stack Overflow",
    "medium": "Medium",
    "notion": "Notion",
    "figma": "Figma",
    "etsy": "Etsy",
    "ebay": "eBay",
    "steam": "Steam",
    "discord": "Discord",
    "pinterest": "Pinterest",
    "tiktok": "TikTok",
    "netflix": "Netflix",
    "imdb": "IMDb",
    "apple": "Apple",
    "adobe": "Adobe",
    "microsoft": "Microsoft",
}

job = BackgroundJob(
    processed=0,
    total=0,
    moving=0,
    unchanged=0,
    skipped=0,
    created=0,
    phase="idle",
    draft=None,
    message=None,
    cooldown_remaining=0,
    model=None,
)
_drafts: dict[str, dict] = {}

get_status = job.get_status
is_running = job.is_running
cancel = job.cancel


def _text(language: str | None, english: str, german: str) -> str:
    if (language or "").lower().startswith("de"):
        return german
    return english


def _clean_line(line: str) -> tuple[bool, str]:
    raw = line.strip().strip("`")
    if not raw or raw.lower().startswith(("allowed", "folder", "ordner", "example", "beispiel")):
        return False, ""
    child = raw.startswith(("- ", "* ", "• "))
    if child:
        raw = raw[2:]
    raw = re.sub(r"^\d+\s*[\.\)\-:]\s*", "", raw.strip())
    if len(raw) > NAME_LIMIT:
        return False, ""
    if ":" in raw:
        head, _tail = raw.split(":", 1)
        if 0 < len(head.strip()) <= NAME_LIMIT:
            raw = head
    name = re.sub(r"\s+", " ", raw).strip(" -–—*•")
    if not name or len(name) > NAME_LIMIT:
        return False, ""
    return child, name


def parse_structure(text: str) -> list[dict]:
    """Turn a model reply into at most 16 folders, each with at most 4 subfolders."""
    folders: list[dict] = []
    seen: set[str] = set()
    for line in (text or "").splitlines():
        child, name = _clean_line(line)
        if not name:
            continue
        key = name.casefold()
        if child and folders:
            children = folders[-1]["children"]
            if len(children) >= MAX_CHILDREN or key in {item.casefold() for item in children}:
                continue
            children.append(name)
            continue
        if key in seen or len(folders) >= MAX_TOPS:
            continue
        seen.add(key)
        folders.append({"name": name, "children": []})
    return folders


def folder_paths(structure: list[dict]) -> list[str]:
    paths: list[str] = []
    for folder in structure:
        paths.append(folder["name"])
        for child in folder["children"]:
            paths.append(f"{folder['name']} / {child}")
    return paths


def _norm(value: str) -> str:
    return re.sub(r"\s+", " ", value.casefold().replace("\\", "/")).strip()


def match_folder(line: str, paths: list[str]) -> str | None:
    _child, name = _clean_line(line)
    if not name:
        return None
    by_norm = {_norm(path): path for path in paths}
    found = by_norm.get(_norm(name))
    if found:
        return found
    tails = [path for path in paths if _norm(path.split(" / ")[-1]) == _norm(name)]
    if len(tails) == 1:
        return tails[0]
    return None


def parse_assignments(text: str, paths: list[str], count: int) -> list[str | None]:
    """Align a model reply with one batch. Unknown lines stay unassigned."""
    lines = [line for line in (text or "").splitlines() if line.strip()]
    matched = [match_folder(line, paths) for line in lines]
    matched = [item for item in matched if item]
    if len(lines) == count:
        return [match_folder(line, paths) for line in lines]
    if len(matched) == count:
        return matched
    return [None] * count


def library_digest(bookmarks: list[dict], collections: list[dict]) -> str:
    names = {row["id"]: row.get("name") or "" for row in collections}
    counts: Counter[str] = Counter()
    samples: dict[str, list[str]] = defaultdict(list)
    for bookmark in bookmarks:
        folder = names.get(bookmark.get("collection_id") or "", "") or "Inbox"
        counts[folder] += 1
        title = (bookmark.get("title") or "").strip()
        if title and len(samples[folder]) < 2:
            samples[folder].append(title[:80])
    lines = ["Largest current folders:"]
    for name, count in counts.most_common(30):
        lines.append(f"- {name} ({count})")
    lines.append("Sample titles:")
    shown = 0
    for name, _count in counts.most_common(40):
        for title in samples[name]:
            lines.append(f"- {title}")
            shown += 1
            if shown >= 80:
                break
        if shown >= 80:
            break
    return "\n".join(lines)[:6000]


def _host(url: str | None) -> str:
    try:
        return (urlparse(url or "").hostname or "").lower().removeprefix("www.")
    except ValueError:
        return ""


def site_key(url: str | None) -> str:
    """The site a link belongs to. youtu.be and youtube.com are the same site."""
    host = _host(url)
    if not host:
        return ""
    if host == "youtu.be" or host == "youtube.com" or host.endswith(".youtube.com"):
        return "youtube"
    parts = host.split(".")
    if len(parts) >= 3 and parts[-2] in {"co", "com", "ac"} and len(parts[-1]) == 2:
        stem = parts[-3]
    elif len(parts) >= 2:
        stem = parts[-2]
    else:
        stem = parts[0]
    if stem in GENERIC_SITES:
        return ""
    return stem


def site_label(key: str) -> str:
    if key in SITE_LABELS:
        return SITE_LABELS[key]
    return key[:1].upper() + key[1:] if key else ""


def link_folders(bookmarks: list[dict]) -> dict[str, str]:
    """Bookmark id to folder name, for sites that occur often enough.

    These assignments do not go through the model. A YouTube link stays a
    YouTube link even when the title talks about something else.
    """
    grouped: dict[str, list[str]] = defaultdict(list)
    for bookmark in bookmarks:
        key = site_key(bookmark.get("url"))
        if key:
            grouped[key].append(bookmark["id"])
    assigned: dict[str, str] = {}
    for key, ids in grouped.items():
        if len(ids) < MIN_SITE_GROUP:
            continue
        name = site_label(key)
        for bookmark_id in ids:
            assigned[bookmark_id] = name
    return assigned


def _load_rows():
    with SessionLocal() as db:
        bookmarks = [
            {
                "id": row.id,
                "title": row.title or "",
                "url": row.url or "",
                "collection_id": row.collection_id,
            }
            for row in db.query(Bookmark.id, Bookmark.title, Bookmark.url, Bookmark.collection_id)
            .filter(Bookmark.deleted_at.is_(None)).all()
        ]
        collections = [
            {"id": row.id, "name": row.name or "", "parent_id": row.parent_id}
            for row in db.query(Collection.id, Collection.name, Collection.parent_id).all()
        ]
    return bookmarks, collections


def _backup() -> None:
    from database import DB_PATH
    from services.backup_service import BACKUP_DIR, _snapshot

    BACKUP_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    destination = BACKUP_DIR / f"before-folder-sort-{datetime.now():%Y-%m-%d-%H%M%S}.db"
    _snapshot(DB_PATH, destination)


def _ensure_folder(db, name: str, parent_id: str | None) -> str:
    query = db.query(Collection).filter(Collection.name == name)
    if parent_id is None:
        query = query.filter(Collection.parent_id.is_(None))
    else:
        query = query.filter(Collection.parent_id == parent_id)
    row = query.first()
    if row is None:
        row = Collection(name=name[:255], parent_id=parent_id)
        db.add(row)
        db.commit()
        db.refresh(row)
    return row.id


def place_bookmarks(db, assignments: dict[str, list[str]]) -> dict:
    """Create the named folders and move the assigned bookmarks."""
    created = 0
    moved = 0
    folder_ids: dict[str, str] = {}
    parents = sorted({path.split(" / ")[0] for path in assignments})
    for name in parents:
        before = db.query(Collection).filter(Collection.name == name, Collection.parent_id.is_(None)).first()
        folder_ids[name] = _ensure_folder(db, name, None)
        if before is None:
            created += 1
    for path in assignments:
        if " / " not in path:
            continue
        parent_name, child_name = path.split(" / ", 1)
        parent_id = folder_ids[parent_name]
        before = db.query(Collection).filter(Collection.name == child_name, Collection.parent_id == parent_id).first()
        folder_ids[path] = _ensure_folder(db, child_name, parent_id)
        if before is None:
            created += 1
    for path, bookmark_ids in assignments.items():
        target = folder_ids.get(path)
        if target is None or not bookmark_ids:
            continue
        for start in range(0, len(bookmark_ids), 200):
            chunk = bookmark_ids[start:start + 200]
            moved += move_bookmarks(db, chunk, target)
    return {"moved": moved, "created": created}


async def _ask(prompt: str, context: str, provider_config: dict, language: str | None, limit: int) -> tuple[str, float]:
    from services.llm_service import LLMService

    started = time.monotonic()
    raw = await LLMService.ask_llm(
        prompt=prompt,
        context=context,
        provider_config=provider_config,
        title="Folder sort",
        url="",
        think=False,
        options={"num_predict": limit, "temperature": 0},
        language=language,
        context_kind="folders",
        timeout=600,
        keep_alive="30m",
    )
    return raw or "", time.monotonic() - started


async def _propose(digest: str, provider_config: dict, language: str | None) -> tuple[list[dict], float]:
    prompt = (
        "Invent a new folder structure for this whole bookmark library. "
        "You may invent short names that summarize the titles. "
        "Use 8 to 16 folders. At most one subfolder level. At most 4 subfolders under one folder. "
        "Names are 1 to 3 words. Do not copy the old nesting. "
        "Reply with folder names only, one per line. A subfolder line starts with '- '. "
        "No numbering and no explanation."
    )
    raw, elapsed = await _ask(prompt, digest, provider_config, language, 500)
    structure = parse_structure(raw)
    if len(structure) >= 4:
        return structure, elapsed
    raw, extra = await _ask(
        "Reply with exactly 12 short folder names, one per line, and nothing else.",
        digest,
        provider_config,
        language,
        300,
    )
    return parse_structure(raw), elapsed + extra


async def _assign_batch(
    batch: list[dict],
    paths: list[str],
    provider_config: dict,
    language: str | None,
) -> tuple[list[str | None], float]:
    listing = "\n".join(paths)
    records = "\n".join(
        f"{index + 1}. {(item.get('title') or 'Untitled')[:70]} | {(item.get('url') or '')[:90]}"
        for index, item in enumerate(batch)
    )
    prompt = (
        "Allowed folders:\n"
        f"{listing}\n\n"
        f"Reply with exactly {len(batch)} lines. "
        "Line i is the folder for bookmark i. Decide from the link, not only the title. "
        "Copy a folder path from the list. No numbering and no explanation."
    )
    raw, elapsed = await _ask(prompt, records, provider_config, language, 400)
    assigned = parse_assignments(raw, paths, len(batch))
    if sum(item is not None for item in assigned) >= max(1, len(batch) // 2):
        return assigned, elapsed
    raw, extra = await _ask(prompt, records, provider_config, language, 400)
    return parse_assignments(raw, paths, len(batch)), elapsed + extra


async def _run(provider_config: dict | None, language: str | None) -> None:
    config = dict(provider_config or {})
    config.setdefault("provider", "ollama")
    pacer = TaggingPacer(True, lambda stage, count: job.state.update(
        phase=stage,
        cooldown_remaining=count if stage == "cooldown" else 0,
    ))
    job.state["phase"] = "reading"
    bookmarks, collections = await asyncio.to_thread(_load_rows)
    job.state["total"] = len(bookmarks)
    job.state["model"] = config.get("model")
    if job.cancelled:
        job.state["phase"] = "cancelled"
        return
    if not bookmarks:
        job.state["phase"] = "done"
        job.state["message"] = _text(language, "There are no bookmarks to sort.", "Es gibt keine Lesezeichen zum Sortieren.")
        return

    job.state["phase"] = "planning"
    job.state["message"] = _text(
        language,
        "Waiting for Ollama. The first answer can take a few minutes while the model loads.",
        "Warte auf Ollama. Die erste Antwort kann ein paar Minuten dauern, während das Modell lädt.",
    )
    by_link = link_folders(bookmarks)
    try:
        structure, elapsed = await _propose(library_digest(bookmarks, collections), config, language)
    except Exception as error:
        if not by_link:
            job.state["phase"] = "error"
            job.state["message"] = _text(
                language,
                str(error),
                "Ollama hat zu lange gebraucht. Es wurde nichts verschoben. Starte die Sortierung noch einmal, das Modell bleibt jetzt geladen.",
            )
            return
        structure = []
        elapsed = 0
    await pacer.rest(max(elapsed, REST_SECONDS), "planning")
    if job.cancelled:
        job.state["phase"] = "cancelled"
        job.state["message"] = _text(language, "Stopped before anything was moved.", "Gestoppt, bevor etwas verschoben wurde.")
        return
    known = {folder["name"].casefold() for folder in structure}
    known.update(child.casefold() for folder in structure for child in folder["children"])
    for name in sorted(set(by_link.values())):
        if name.casefold() not in known:
            structure.append({"name": name, "children": []})
            known.add(name.casefold())
    paths = folder_paths(structure)
    if len(paths) < 4:
        job.state["phase"] = "error"
        job.state["message"] = _text(
            language,
            "The local model did not return a folder structure. Nothing was moved.",
            "Die lokale KI hat keine Ordnerstruktur geliefert. Es wurde nichts verschoben.",
        )
        return

    def resolve(name: str) -> str:
        target = _norm(name)
        exact = [path for path in paths if _norm(path) == target or _norm(path.split(" / ")[-1]) == target]
        if len(exact) == 1:
            return exact[0]
        return name

    assigned: dict[str, list[str]] = defaultdict(list)
    remaining = []
    for bookmark in bookmarks:
        folder = by_link.get(bookmark["id"])
        if folder:
            assigned[resolve(folder)].append(bookmark["id"])
        else:
            remaining.append(bookmark)
    job.state["processed"] = len(bookmarks) - len(remaining)
    job.state["phase"] = "sorting"
    job.state["message"] = None
    for start in range(0, len(remaining), BATCH_SIZE):
        if job.cancelled:
            job.state["phase"] = "cancelled"
            job.state["message"] = _text(language, "Stopped before anything was moved.", "Gestoppt, bevor etwas verschoben wurde.")
            return
        batch = remaining[start:start + BATCH_SIZE]
        try:
            choices, elapsed = await _assign_batch(batch, paths, config, language)
        except Exception:
            choices = [None] * len(batch)
            elapsed = 0
        for bookmark, choice in zip(batch, choices):
            if choice:
                assigned[choice].append(bookmark["id"])
        job.state["processed"] = len(bookmarks) - len(remaining) + min(len(remaining), start + len(batch))
        await pacer.rest(max(elapsed, REST_SECONDS), "sorting")

    moving = sum(len(ids) for ids in assigned.values())
    if moving == 0:
        job.state["phase"] = "error"
        job.state["message"] = _text(
            language,
            "The local model did not assign any bookmarks. Nothing was moved.",
            "Die lokale KI hat keine Lesezeichen zugeordnet. Es wurde nichts verschoben.",
        )
        return

    job.state["phase"] = "moving"
    job.state["message"] = _text(language, "Moving bookmarks into the new folders.", "Lesezeichen werden in die neuen Ordner verschoben.")
    try:
        await asyncio.to_thread(_backup)
        with SessionLocal() as db:
            result = place_bookmarks(db, assigned)
    except Exception as error:
        job.state["phase"] = "error"
        job.state["message"] = str(error)
        return
    job.state["moving"] = result["moved"]
    job.state["created"] = result["created"]
    job.state["unchanged"] = len(bookmarks) - result["moved"]
    job.state["processed"] = len(bookmarks)
    job.state["phase"] = "done"
    job.state["message"] = _text(
        language,
        f"Moved {result['moved']} bookmarks into {result['created']} folders. {len(bookmarks) - result['moved']} stayed. Empty old folders are left in place.",
        f"{result['moved']} Lesezeichen wurden in {result['created']} Ordner verschoben. {len(bookmarks) - result['moved']} bleiben liegen. Leere alte Ordner bleiben stehen.",
    )


async def start(provider_config: dict | None = None, language: str | None = None) -> dict:
    async def runner(active_job: BackgroundJob) -> None:
        await _run(provider_config, language)

    return await job.start(runner, reset={"phase": "planning", "draft": None, "message": None, "processed": 0})


def discard_draft(draft_id: str) -> None:
    _drafts.pop(draft_id, None)


def apply_draft(db, draft_id: str, enabled_keys: list[str] | None) -> dict:
    """Kept for the existing apply endpoint. The sort job moves bookmarks itself."""
    plan = _drafts.get(draft_id)
    if plan is None:
        raise KeyError(draft_id)
    selected = set(enabled_keys) if enabled_keys is not None else {folder["key"] for folder in plan["folders"]}
    grouped: dict[str, list[str]] = defaultdict(list)
    for folder in plan["folders"]:
        if folder["key"] not in selected or not folder.get("bookmark_ids"):
            continue
        parent = folder.get("parent_name")
        path = f"{parent} / {folder['name']}" if parent else folder["name"]
        grouped[path].extend(folder["bookmark_ids"])
    result = place_bookmarks(db, grouped)
    _drafts.pop(draft_id, None)
    job.state["draft"] = None
    job.state["phase"] = "idle"
    return {"moved": result["moved"], "folders_created": result["created"]}
