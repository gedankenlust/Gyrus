"""Best-effort upkeep of data derived from bookmark rows.

The database is the source of truth. The Markdown Brain mirror, the semantic
search vectors and the cached design / site-structure files are all rebuilt
from it, so failures here are logged and never break the row operation that
triggered them.
"""
import asyncio
import logging
import shutil

from database import DATA_DIR

logger = logging.getLogger(__name__)


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


def _drop_vectors(ids: list[str]) -> None:
    """Best-effort removal of semantic-search vectors for the given bookmarks.
    Trashed/purged bookmarks must not occupy KNN slots or leave orphan rows."""
    if not ids:
        return
    try:
        from services import vector_store
        vector_store.delete_many(ids)
    except Exception as exc:
        logger.warning("Bulk vector removal failed: %s", exc)


def delete_generated_artifacts(ids: list[str]) -> None:
    """Remove cached design and site-structure files for hard-deleted rows."""
    snapshot_root = DATA_DIR / "visual_snapshots"
    structure_root = DATA_DIR / "site_structure"
    for bookmark_id in ids:
        shutil.rmtree(snapshot_root / bookmark_id, ignore_errors=True)
        if structure_root.exists():
            for path in structure_root.glob(f"{bookmark_id}-*.json"):
                path.unlink(missing_ok=True)


async def index_bookmark_embedding(bookmark_id: str, text: str) -> bool:
    """Compute and store an embedding for a bookmark (best-effort, never blocks
    the caller).  Called after page content is scraped so semantic search can
    find this bookmark by meaning, not just keywords."""
    from services import ai_policy
    if not ai_policy.enabled() or not text or not text.strip():
        return False
    try:
        from services.embedding_service import get_embedding, configuration_key
        from services import vector_store
        policy_generation = ai_policy.generation()
        vec = await get_embedding(text)
        if not ai_policy.enabled() or policy_generation != ai_policy.generation():
            return False
        # The vector table lives in the same SQLite file and waits on its
        # busy timeout like any other writer, so store it off the event loop.
        return await asyncio.to_thread(
            vector_store.upsert, bookmark_id, vec, model_key=configuration_key()
        )
    except Exception as e:
        # Ollama down, model missing, DB write error — none of these should
        # affect the caller; semantic search simply won't find this bookmark.
        logger.debug("embedding indexing skipped for %s: %s", bookmark_id, e)
        return False
