import logging

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session
from database import get_db
from schemas.bookmark import BookmarkSummaryOut
from services import ai_policy
from services.search_service import search_bookmarks, search_bookmarks_semantic
from services.bookmark_response_service import enrich_bookmark_summary

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/search", tags=["search"])


@router.get("", response_model=list[BookmarkSummaryOut])
def search(
    q: str = "",
    limit: int = Query(default=100, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    db: Session = Depends(get_db),
):
    results = search_bookmarks(db, q, limit=limit, offset=offset)
    return [enrich_bookmark_summary(bm) for bm in results]


@router.get("/semantic", response_model=list[BookmarkSummaryOut], dependencies=[Depends(ai_policy.require_ai)])
async def search_semantic(
    q: str = "",
    limit: int = Query(default=20, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    db: Session = Depends(get_db),
):
    """Semantic / meaning-based search via local embeddings.

    Returns bookmarks ranked by vector similarity to the query — finds related
    content even when the exact words don't appear.  Requires Ollama with an
    embedding model (default: nomic-embed-text).  Returns an empty list when
    Ollama is unreachable so the UI can fall back to keyword search silently.
    """
    if not q.strip():
        return []
    results = await search_bookmarks_semantic(db, q, limit=limit, offset=offset)
    return [enrich_bookmark_summary(bm) for bm in results]


@router.get("/status")
async def semantic_search_status():
    """Check whether semantic search is currently available (Ollama reachable +
    embedding model installed + at least some vectors indexed).

    Uses Ollama's lightweight /api/tags listing instead of running a real
    embedding inference — a cold model would otherwise make this check take
    seconds on every app start."""
    import httpx
    from services import vector_store
    from services.embedding_service import current_model, current_base_url

    if not ai_policy.enabled():
        return {"available": False, "indexed": vector_store.count(), "message": "AI is disabled.", **_progress()}
    model, base_url = current_model(), current_base_url()

    indexed = vector_store.count()
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            resp = await client.get(f"{base_url}/api/tags")
            resp.raise_for_status()
            models = [m.get("name", "") for m in resp.json().get("models", [])]
        if any((name if ":" in name else name + ":latest") == (model if ":" in model else model + ":latest") for name in models):
            from services.embedding_service import configuration_key
            available = indexed > 0 and vector_store.matches_configuration(configuration_key())
            message = f"Ready — {indexed} bookmarks indexed." if available else "Rebuild the search index for the selected embedding model."
        else:
            available = False
            message = (
                f"Embedding model '{model}' is not installed. "
                f"Run: ollama pull {model}"
            )
    except Exception:
        available = False
        message = (
            f"Couldn't reach Ollama at {base_url}. "
            "Make sure it's running to use semantic search."
        )
    return {"available": available, "indexed": indexed, "message": message, **_progress()}


_reindex_running = False
_reindex_completed = 0
_reindex_total = 0
_reindex_error = None
_reindex_error_code = None


def _progress():
    return dict(reindex_running=_reindex_running, reindex_completed=_reindex_completed,
                reindex_total=_reindex_total, reindex_error=_reindex_error,
                reindex_error_code=_reindex_error_code)


@router.post("/reindex", dependencies=[Depends(ai_policy.require_ai)])
async def reindex_embeddings(db: Session = Depends(get_db)):
    """Stage every embedding before atomically replacing the existing index."""
    global _reindex_running, _reindex_completed, _reindex_total, _reindex_error, _reindex_error_code
    if _reindex_running:
        return {"status": "already_running"}
    _reindex_running = True
    _reindex_completed = _reindex_total = 0
    _reindex_error = None
    _reindex_error_code = None

    async def _run():
        global _reindex_running, _reindex_completed, _reindex_total, _reindex_error, _reindex_error_code
        import asyncio
        import json
        import tempfile
        from models.bookmark import Bookmark
        from services import vector_store
        from services.embedding_service import get_embedding, configuration_key
        from database import SessionLocal

        def snapshot():
            with SessionLocal() as session:
                return list(session.query(Bookmark.id, Bookmark.scraped_content, Bookmark.title, Bookmark.description)
                            .filter(Bookmark.scraped_content.isnot(None), Bookmark.deleted_at.is_(None))
                            .order_by(Bookmark.id).all())

        try:
            rows = snapshot()
            _reindex_total = len(rows)
            if not rows:
                return
            key, generation = configuration_key(), ai_policy.generation()
            dimension = None
            with tempfile.TemporaryFile(mode="w+t") as staging:
                for bm_id, content, title, desc in rows:
                    vector = await get_embedding(content or f"{title or ''} {desc or ''}".strip())
                    if generation != ai_policy.generation() or not ai_policy.enabled():
                        raise ValueError("AI settings changed. Please restart indexing.")
                    if not vector:
                        raise ValueError("The embedding model returned an empty vector.")
                    dimension = dimension or len(vector)
                    if len(vector) != dimension:
                        raise ValueError("The embedding model returned inconsistent dimensions.")
                    staging.write(json.dumps([bm_id, vector]) + "\n")
                    _reindex_completed += 1
                    await asyncio.sleep(0)
                if generation != ai_policy.generation() or key != configuration_key():
                    raise ValueError("AI settings changed. Please restart indexing.")
                if rows != snapshot():
                    raise ValueError("The library changed during indexing. Please retry.")
                staging.seek(0)
                vector_store.replace_all((json.loads(line) for line in staging), dimension, key)
        except Exception as error:
            _reindex_error = str(error)
            _reindex_error_code = getattr(error, "code", None)
            logger.warning("Reindex failed; previous index retained: %s", error)
        finally:
            _reindex_running = False

    from services import background
    background.schedule(_run())
    return {"status": "started", "message": "Reindexing embeddings in the background."}
