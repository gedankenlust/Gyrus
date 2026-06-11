from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session
from database import get_db
from schemas.bookmark import BookmarkOut
from services.search_service import search_bookmarks, search_bookmarks_semantic

router = APIRouter(prefix="/api/search", tags=["search"])


def _enrich(bm) -> BookmarkOut:
    item = BookmarkOut.model_validate(bm)
    item.tags = [bt.tag for bt in bm.bookmark_tags]
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
    embedding model installed + at least some vectors indexed)."""
    from services import vector_store
    from services.embedding_service import get_embedding, EmbeddingUnavailableError
    indexed = vector_store.count()
    try:
        await get_embedding("test")
        available = True
        message = f"Ready — {indexed} bookmark(s) indexed."
    except EmbeddingUnavailableError as e:
        available = False
        message = str(e)
    return {"available": available, "indexed": indexed, "message": message}
