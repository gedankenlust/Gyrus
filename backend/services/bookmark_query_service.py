"""Read-only bookmark queries: listing, sorting, pagination, ids and counts.

Nothing here writes, touches the Brain mirror or the vector store, so these
helpers are safe to call from any request thread and from background jobs.
"""
from sqlalchemy import case, func, select
from sqlalchemy.orm import Session, selectinload, defer

from models.bookmark import Bookmark
from models.tag import Tag, BookmarkTag

_SORT_COLUMNS = {
    "created_at": Bookmark.created_at,
    "updated_at": Bookmark.updated_at,
    "title": Bookmark.title,
    "url": Bookmark.url,
}
# SQLite allows at most 32,766 bound parameters per statement. Selections
# ("select all" in a large library) are chunked well below that.
ID_CHUNK_SIZE = 500


def _chunks(ids: list[str], size: int = ID_CHUNK_SIZE):
    for start in range(0, len(ids), size):
        yield ids[start:start + size]


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
    q = (
        db.query(Bookmark)
        .options(selectinload(Bookmark.bookmark_tags).selectinload(BookmarkTag.tag),
                 defer(Bookmark.scraped_content, raiseload=True), defer(Bookmark.notes, raiseload=True))
        .filter(Bookmark.deleted_at.is_(None))
    )
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
        min_tag = (
            select(func.min(Tag.name))
            .select_from(Tag)
            .join(BookmarkTag, BookmarkTag.tag_id == Tag.id)
            .where(BookmarkTag.bookmark_id == Bookmark.id)
            .correlate(Bookmark)
            .scalar_subquery()
        )
        name_expr = func.lower(min_tag)
        direction = name_expr.asc() if order == "asc" else name_expr.desc()
        q = q.order_by(min_tag.is_(None), direction)
    elif sort_by == "favicon":
        # Group bookmarks from the same site together. We sort by the URL's host
        # (not favicon_path) because favicons are fetched lazily — a favicon-based
        # sort would scramble as icons load in. The host is always known, so this
        # groups deterministically and immediately. www. is stripped.
        after = func.substr(Bookmark.url, func.instr(Bookmark.url, '://') + 3)
        first_slash = func.instr(after, '/')
        host = func.lower(func.substr(
            after, 1, func.iif(first_slash > 0, first_slash - 1, func.length(after))))
        host = func.iif(host.like('www.%'), func.substr(host, 5), host)
        hdir = host.asc() if order == "asc" else host.desc()
        q = q.order_by(hdir, func.lower(Bookmark.title))
    else:
        col = _SORT_COLUMNS.get(sort_by, Bookmark.created_at)
        # Case-insensitive sort for text columns
        if sort_by in ("title", "url"):
            col_expr = func.lower(col)
        else:
            col_expr = col
        q = q.order_by(col_expr.asc() if order == "asc" else col_expr.desc())

    # OFFSET paging needs a total order. Imports create many rows with the
    # same created_at, and equal titles/hosts/tags are common; without a
    # unique tiebreaker SQLite may return tied rows in a different order per
    # page, so bookmarks repeated or silently went missing while scrolling.
    q = q.order_by(Bookmark.id)
    return q.offset(offset).limit(limit).all()


def get_bookmark(db: Session, bookmark_id: str, include_deleted: bool = False) -> Bookmark | None:
    q = (
        db.query(Bookmark)
        .options(
            selectinload(Bookmark.bookmark_tags).selectinload(BookmarkTag.tag),
            selectinload(Bookmark.bookmark_notes),
        )
        .filter(Bookmark.id == bookmark_id)
    )
    if not include_deleted:
        q = q.filter(Bookmark.deleted_at.is_(None))
    return q.first()


def list_bookmark_ids(
    db: Session,
    collection_id: str | None = None,
    tag: str | None = None,
    dead_only: bool = False,
    unread_only: bool = False,
    q: str | None = None,
) -> list[str]:
    """Every active id matching the list filters (for "select all")."""
    query = db.query(Bookmark.id).filter(Bookmark.deleted_at.is_(None))
    if collection_id:
        query = query.filter(Bookmark.collection_id == collection_id)
    if dead_only:
        query = query.filter(Bookmark.is_dead == True)
    if unread_only:
        query = query.filter(Bookmark.is_read == False)
    if tag:
        query = (query
                 .join(BookmarkTag, BookmarkTag.bookmark_id == Bookmark.id)
                 .join(Tag, Tag.id == BookmarkTag.tag_id)
                 .filter(Tag.name == tag))
    if q:
        from services.search_service import search_bookmarks
        matches = search_bookmarks(db, q, limit=250_000)
        matching = {bookmark.id for bookmark in matches}
        return [row.id for row in query.all() if row.id in matching]
    return [row.id for row in query.all()]


def tagged_bookmark_ids(db: Session, bookmark_ids: list[str]) -> list[str]:
    """Which of the given active bookmarks carry at least one tag."""
    ids = list(dict.fromkeys(bookmark_ids))
    tagged = []
    for chunk in _chunks(ids):
        rows = db.query(Bookmark.id).filter(
            Bookmark.id.in_(chunk),
            Bookmark.deleted_at.is_(None),
            Bookmark.bookmark_tags.any(),
        ).all()
        tagged.extend(row.id for row in rows)
    return tagged


def count_active(db: Session) -> int:
    return db.query(Bookmark).filter(Bookmark.deleted_at.is_(None)).count()


def count_dead(db: Session) -> int:
    return db.query(Bookmark).filter(
        Bookmark.deleted_at.is_(None), Bookmark.is_dead == True
    ).count()


def count_unread(db: Session) -> int:
    return db.query(Bookmark).filter(
        Bookmark.deleted_at.is_(None), Bookmark.is_read == False
    ).count()


def library_counts(db: Session) -> dict[str, int]:
    """All sidebar counts in one table scan."""
    active = Bookmark.deleted_at.is_(None)
    total, dead, unread, trash = db.query(
        func.sum(case((active, 1), else_=0)),
        func.sum(case((active & Bookmark.is_dead.is_(True), 1), else_=0)),
        func.sum(case((active & Bookmark.is_read.is_(False), 1), else_=0)),
        func.sum(case((Bookmark.deleted_at.is_not(None), 1), else_=0)),
    ).one()
    return {
        "total": total or 0,
        "dead": dead or 0,
        "unread": unread or 0,
        "trash": trash or 0,
    }


def get_trashed(db: Session, limit: int = 200, offset: int = 0) -> list[Bookmark]:
    """List bookmarks currently in the Trash, most recently deleted first."""
    return (
        db.query(Bookmark)
        .options(selectinload(Bookmark.bookmark_tags).selectinload(BookmarkTag.tag))
        .filter(Bookmark.deleted_at.is_not(None))
        .order_by(Bookmark.deleted_at.desc())
        .offset(offset)
        .limit(limit)
        .all()
    )


def count_trashed(db: Session) -> int:
    return db.query(Bookmark).filter(Bookmark.deleted_at.is_not(None)).count()
