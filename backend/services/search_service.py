from sqlalchemy import text
from sqlalchemy.orm import Session
from models.bookmark import Bookmark, BookmarkNote
from models.tag import Tag, BookmarkTag


def search_bookmarks(db: Session, query: str, limit: int = 50, offset: int = 0) -> list[Bookmark]:
    q = query.strip()
    if not q:
        return []

    # 1. Full-text match on title / url / description / legacy notes (ranked).
    ids: list[str] = []
    try:
        safe_query = q.replace('"', '""')
        fts_query = f'"{safe_query}"*'
        rows = db.execute(
            text("SELECT id FROM bookmarks_fts WHERE bookmarks_fts MATCH :q ORDER BY rank"),
            {"q": fts_query},
        )
        ids = [row[0] for row in rows]
    except Exception:
        pattern = f"%{q}%"
        ids = [
            row[0]
            for row in db.query(Bookmark.id).filter(
                Bookmark.title.ilike(pattern)
                | Bookmark.url.ilike(pattern)
                | Bookmark.description.ilike(pattern)
            )
        ]

    # 2. Also match the structured per-bookmark notes (incl. saved AI answers),
    #    which the FTS index doesn't cover. Append any new hits after the
    #    ranked full-text results.
    seen = set(ids)
    note_pattern = f"%{q}%"
    note_rows = (
        db.query(BookmarkNote.bookmark_id)
        .filter(BookmarkNote.content.ilike(note_pattern))
        .distinct()
        .all()
    )
    for (bookmark_id,) in note_rows:
        if bookmark_id not in seen:
            seen.add(bookmark_id)
            ids.append(bookmark_id)

    # 3. Also match by tag name, so searching for a tag finds every bookmark
    #    carrying it (the FTS index doesn't cover tags either).
    tag_pattern = f"%{q}%"
    tag_rows = (
        db.query(BookmarkTag.bookmark_id)
        .join(Tag, BookmarkTag.tag_id == Tag.id)
        .filter(Tag.name.ilike(tag_pattern))
        .distinct()
        .all()
    )
    for (bookmark_id,) in tag_rows:
        if bookmark_id not in seen:
            seen.add(bookmark_id)
            ids.append(bookmark_id)

    # 4. Paginate the merged id list, then load and return in order.
    page_ids = ids[offset: offset + limit]
    if not page_ids:
        return []

    bookmarks_map = {
        bm.id: bm
        for bm in db.query(Bookmark).filter(Bookmark.id.in_(page_ids)).all()
    }
    return [bookmarks_map[i] for i in page_ids if i in bookmarks_map]
