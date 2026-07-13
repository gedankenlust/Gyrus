import logging

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session
from database import get_db
from schemas.bookmark import BookmarkOut
from services.search_service import search_bookmarks, search_bookmarks_semantic
from services import visual_snapshot_service

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/search", tags=["search"])


def _enrich(bm) -> BookmarkOut:
    item = BookmarkOut.model_validate(bm)
    item.tags = [bt.tag for bt in bm.bookmark_tags]
    captured_at, complete = visual_snapshot_service.snapshot_summary(bm.id)
    item.design_snapshot_captured_at = captured_at
    item.design_snapshot_complete = complete
    return item


@router.get("", response_model=list[BookmarkOut])
def search(q: str = "", limit: int = 100, offset: int = 0, db: Session = Depends(get_db)):
    results = search_bookmarks(db, q, limit=limit, offset=offset)
    return [_enrich(bm) for bm in results]


@router.get("/semantic", response_model=list[BookmarkOut])
async def search_semantic(q: str = "", limit: int = 20, db: Session = Depends(get_db)):
    """Semantic / meaning-based search via local embeddings.

    Returns bookmarks ranked by vector similarity to the query — finds related
    content even when the exact words don't appear.  Requires Ollama with an
    embedding model (default: nomic-embed-text).  Returns an empty list when
    Ollama is unreachable so the UI can fall back to keyword search silently.
    """
    if not q.strip():
        return []
    results = await search_bookmarks_semantic(db, q, limit=limit)
    return [_enrich(bm) for bm in results]


@router.get("/status")
async def semantic_search_status():
    """Check whether semantic search is currently available (Ollama reachable +
    embedding model installed + at least some vectors indexed).

    Uses Ollama's lightweight /api/tags listing instead of running a real
    embedding inference — a cold model would otherwise make this check take
    seconds on every app start."""
    import httpx
    from services import vector_store
    from services.embedding_service import DEFAULT_MODEL, DEFAULT_BASE_URL

    indexed = vector_store.count()
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            resp = await client.get(f"{DEFAULT_BASE_URL}/api/tags")
            resp.raise_for_status()
            models = [m.get("name", "") for m in resp.json().get("models", [])]
        if any(name.split(":")[0] == DEFAULT_MODEL for name in models):
            available = True
            message = f"Ready — {indexed} bookmarks indexed."
        else:
            available = False
            message = (
                f"Embedding model '{DEFAULT_MODEL}' is not installed. "
                f"Run: ollama pull {DEFAULT_MODEL}"
            )
    except Exception:
        available = False
        message = (
            f"Couldn't reach Ollama at {DEFAULT_BASE_URL}. "
            "Make sure it's running to use semantic search."
        )
    return {"available": available, "indexed": indexed, "message": message}


_reindex_running = False


@router.post("/reindex")
async def reindex_embeddings(db: Session = Depends(get_db)):
    """Recompute embeddings for every non-trashed bookmark with scraped
    content (a repair button: also refreshes stale vectors).  Runs as a
    background asyncio task so the request returns immediately."""
    global _reindex_running
    if _reindex_running:
        from services import vector_store
        return {"status": "already_running", "indexed": vector_store.count()}
    # Set the flag here, not inside the task — create_task doesn't start the
    # coroutine immediately, so a quick second POST could otherwise pass the
    # check above and start a duplicate run.
    _reindex_running = True

    async def _run():
        global _reindex_running
        try:
            from models.bookmark import Bookmark
            from services.bookmark_service import index_bookmark_embedding
            from services import vector_store
            from database import SessionLocal

            with SessionLocal() as session:
                rows = (
                    session.query(Bookmark.id, Bookmark.scraped_content, Bookmark.title, Bookmark.description)
                    .filter(Bookmark.scraped_content.isnot(None), Bookmark.deleted_at.is_(None))
                    .all()
                )
            import asyncio
            from services.embedding_service import get_embedding

            # Rebuild the vector table to match the active embedding model's
            # dimension first — switching models (e.g. nomic 768 → bge-m3 1024)
            # would otherwise make every insert fail. We learn the dimension
            # from the first embeddable row; if embedding is unavailable we bail
            # out and leave the existing index untouched (keyword search still works).
            sample_vec = None
            for _, content, title, desc in rows:
                text = content or f"{title or ''} {desc or ''}".strip()
                if not text:
                    continue
                try:
                    sample_vec = await get_embedding(text)
                except Exception as e:
                    logger.warning("reindex: embedding unavailable, leaving index as-is: %s", e)
                    return
                break
            if sample_vec is None:
                return  # nothing to index
            vector_store.reset_table(len(sample_vec))

            for bm_id, content, title, desc in rows:
                text = content or f"{title or ''} {desc or ''}".strip()
                await index_bookmark_embedding(bm_id, text)
                await asyncio.sleep(0.1)  # yield between embeddings
        finally:
            _reindex_running = False

    from services import background
    background.schedule(_run())
    return {"status": "started", "message": "Reindexing embeddings in the background."}
