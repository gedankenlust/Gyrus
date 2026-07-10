import asyncio
import logging

from sqlalchemy import text
from sqlalchemy.orm import Session
from models.bookmark import Bookmark, BookmarkNote, BrainMessage
from models.tag import Tag, BookmarkTag

logger = logging.getLogger(__name__)


async def search_bookmarks_semantic(
    db: Session, query: str, limit: int = 20
) -> list[Bookmark]:
    """Return bookmarks ranked by semantic similarity to *query*.

    Computes a query embedding via Ollama and performs a KNN search in the
    bookmarks_vec table.  Falls back to an empty list (not an error) when
    Ollama is unreachable or no embeddings have been indexed yet.
    Trashed bookmarks are excluded.
    """
    from services.embedding_service import get_embedding, EmbeddingUnavailableError
    from services import vector_store

    try:
        query_vec = await get_embedding(query)
    except EmbeddingUnavailableError as e:
        logger.info("semantic search unavailable: %s", e)
        return []

    pairs = vector_store.search(query_vec, k=limit * 2)
    if not pairs:
        return []

    ids = [bid for bid, _dist in pairs]
    # Load in one query, filter trashed, then restore the distance-rank order.
    bm_map = {
        bm.id: bm
        for bm in db.query(Bookmark)
        .filter(Bookmark.id.in_(ids), Bookmark.deleted_at.is_(None))
        .all()
    }
    ranked = [bm_map[i] for i in ids if i in bm_map]
    return ranked[:limit]


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
                | Bookmark.scraped_content.ilike(pattern)
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

    # 3. Also match persisted AI Brain conversations. They are not "Notes"
    # unless the user promotes them, but users still expect old Q&A to lead
    # back to the bookmark where the conversation happened.
    chat_rows = (
        db.query(BrainMessage.bookmark_id)
        .filter(BrainMessage.content.ilike(note_pattern))
        .distinct()
        .all()
    )
    for (bookmark_id,) in chat_rows:
        if bookmark_id not in seen:
            seen.add(bookmark_id)
            ids.append(bookmark_id)

    # 4. Also match by tag name, so searching for a tag finds every bookmark
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

    # 5. Paginate the merged id list, then load and return in order.
    page_ids = ids[offset: offset + limit]
    if not page_ids:
        return []

    bookmarks_map = {
        bm.id: bm
        for bm in db.query(Bookmark)
        .filter(Bookmark.id.in_(page_ids), Bookmark.deleted_at.is_(None))
        .all()
    }
    return [bookmarks_map[i] for i in page_ids if i in bookmarks_map]
