import logging

from bs4 import BeautifulSoup, Tag
from sqlalchemy import func
from sqlalchemy.orm import Session
from models.bookmark import Bookmark
from models.collection import Collection
from services.url_utils import normalize_url
from services.outbound_url_security import validate_bookmark_url_syntax
from services.collection_validation import validate_placement, MAX_NAME_LENGTH

logger = logging.getLogger(__name__)

MAX_IMPORTED_BOOKMARKS = 20_000
MAX_IMPORTED_COLLECTIONS = 5_000
MAX_IMPORTED_TITLE_CHARS = 1_000
MAX_IMPORTED_COLLECTION_NAME_CHARS = MAX_NAME_LENGTH


class ImportLimitExceeded(ValueError):
    pass


def parse_netscape_html(html_content: str, db: Session,
                        root_folder_name: str | None = None) -> dict:
    soup = BeautifulSoup(html_content, "html.parser")
    stats = {"imported": 0, "skipped": 0, "collections_created": 0, "_imported_bookmarks": []}

    existing: set[str] = {normalize_url(url) for (url,) in db.query(Bookmark.url).all()}
    seen: set[str] = set()

    try:
        # Optional wrapper folder — keeps a given import (e.g. one browser)
        # isolated from others. Reused on re-import so it doesn't duplicate.
        root_pid = None
        name = (root_folder_name or "").strip()[:MAX_IMPORTED_COLLECTION_NAME_CHARS]
        if name:
            root_pid = _get_or_create_collection(db, name, None, stats)

        root_dl = soup.find("dl")
        if root_dl:
            _walk_dl_iterative(root_dl, parent_id=root_pid, db=db, stats=stats,
                               existing=existing, seen=seen)
        else:
            for a in soup.find_all("a", href=True):
                _import_anchor(a, parent_id=root_pid, db=db, stats=stats,
                               existing=existing, seen=seen)
        db.commit()
    except Exception:
        db.rollback()
        raise

    # Create imported mirrors and refresh the index once after the bulk import.
    try:
        from services.brain_sync_service import brain_sync_service
        brain_sync_service.resync_all(db)
    except Exception as exc:
        logger.warning("AI Brain index refresh after import failed: %s", exc)
    stats["_imported_ids"] = [bookmark.id for bookmark in stats.pop("_imported_bookmarks")]
    return stats


def _get_or_create_collection(db: Session, name: str, parent_id, stats: dict):
    """Reuse a folder with the same name and parent, or create it.

    Merging by (name, parent) means re-importing a browser export slots new
    bookmarks into the existing folders instead of duplicating the whole tree.
    """
    safe_name = name.strip()[:MAX_IMPORTED_COLLECTION_NAME_CHARS] or "Unnamed"
    found = db.query(Collection).filter(
        Collection.name == safe_name,
        Collection.parent_id == parent_id,
    ).first()
    if found:
        return found.id
    validate_placement(db, parent_id)
    if stats["collections_created"] >= MAX_IMPORTED_COLLECTIONS:
        raise ImportLimitExceeded(
            f"Bookmark import is limited to {MAX_IMPORTED_COLLECTIONS} folders"
        )
    # Append to the end of the sibling group so imported order is preserved
    # as the manual order.
    max_pos = (db.query(func.max(Collection.position))
               .filter(Collection.parent_id == parent_id).scalar())
    col = Collection(name=safe_name, parent_id=parent_id, icon="folder",
                     position=0 if max_pos is None else max_pos + 1)
    db.add(col)
    db.flush()
    stats["collections_created"] += 1
    return col.id


def _walk_dl_iterative(root_dl: Tag, parent_id, db: Session, stats: dict,
                       existing: set, seen: set) -> None:
    """
    Iterative traversal of the nested DL/DT structure produced by html.parser.

    html.parser quirks:
    - <DT> is implicitly closed by the next <DT>, so subsequent DTs become
      *children* of the first DT rather than siblings.
    - <DL> children of a folder are also nested inside the folder's <DT>.

    We use an explicit stack of (dt_node, parent_collection_id) tuples.
    For each DT we process the bookmark/folder it directly contains, then
    push any nested DT chains (both the sibling chain and sub-folder DLs)
    onto the stack.
    """
    # Find the first DT inside a DL (possibly wrapped in <p> tags)
    first_dt = _first_dt_in(root_dl)
    if not first_dt:
        return

    stack: list[tuple[Tag, object]] = [(first_dt, parent_id)]

    while stack:
        dt, pid = stack.pop()

        direct = [c for c in dt.children if isinstance(c, Tag)]
        h3        = next((c for c in direct if c.name.lower() == "h3"), None)
        a         = next((c for c in direct if c.name.lower() == "a"), None)
        nested_dl = next((c for c in direct if c.name.lower() == "dl"), None)
        next_dt   = next((c for c in direct if c.name.lower() == "dt"), None)
        p_wrap    = next((c for c in direct if c.name.lower() == "p"), None)

        if h3:
            folder_name = h3.get_text(strip=True) or "Unnamed"
            child_pid = _get_or_create_collection(db, folder_name, pid, stats)

            # Push contents of the sub-folder DL onto the stack
            if nested_dl:
                sub_dt = _first_dt_in(nested_dl)
                if sub_dt:
                    stack.append((sub_dt, child_pid))
        elif a and a.get("href"):
            _import_anchor(a, parent_id=pid, db=db, stats=stats,
                           existing=existing, seen=seen)

        # Push the next sibling DT in this chain (same parent)
        # p_wrap is a <p> that html.parser emits between DT runs in some exports
        if next_dt:
            stack.append((next_dt, pid))
        elif p_wrap:
            inner = _first_dt_in(p_wrap)
            if inner:
                stack.append((inner, pid))


def _first_dt_in(node: Tag) -> Tag | None:
    """Return the first <DT> found as a direct child, skipping <p> wrappers."""
    for child in node.children:
        if not isinstance(child, Tag):
            continue
        name = child.name.lower()
        if name == "dt":
            return child
        if name == "p":
            found = _first_dt_in(child)
            if found:
                return found
    return None


def _import_anchor(a: Tag, parent_id, db: Session, stats: dict,
                   existing: set, seen: set) -> None:
    raw = a["href"].strip()
    try:
        validate_bookmark_url_syntax(raw)
    except ValueError:
        stats["skipped"] += 1
        return
    url = normalize_url(raw)
    if url in existing or url in seen:
        stats["skipped"] += 1
        return
    if stats["imported"] >= MAX_IMPORTED_BOOKMARKS:
        raise ImportLimitExceeded(
            f"Bookmark import is limited to {MAX_IMPORTED_BOOKMARKS} bookmarks"
        )
    seen.add(url)
    bookmark = Bookmark(
        title=(a.get_text(strip=True) or url)[:MAX_IMPORTED_TITLE_CHARS],
        url=url,
        collection_id=parent_id,
        source="import",
    )
    db.add(bookmark)
    stats["_imported_bookmarks"].append(bookmark)
    stats["imported"] += 1
