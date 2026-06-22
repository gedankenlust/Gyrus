"""SQLite-vec vector store for semantic search.

Wraps the bookmarks_vec virtual table (created by the v0.7.0 migration) via
apsw — the only Python SQLite adapter that can load extensions on macOS without
a special build flag.  All other DB operations continue to use SQLAlchemy.

Intentionally simple:
  upsert(bookmark_id, vector)  — store / replace a vector
  delete(bookmark_id)          — remove a vector when a bookmark is trashed
  search(query_vec, k)         — return the k nearest bookmark IDs + distances
"""
import logging
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

# Lazy singleton — the apsw connection is opened once on first use.
_conn = None


def _get_conn():
    global _conn
    if _conn is not None:
        return _conn

    import apsw
    import sqlite_vec
    from database import DB_PATH

    conn = apsw.Connection(str(DB_PATH))
    conn.enableloadextension(True)
    sqlite_vec.load(conn)
    conn.enableloadextension(False)
    _conn = conn
    return conn


def reset_table(dim: int) -> None:
    """Drop and recreate bookmarks_vec for a given embedding dimension.

    Different embedding models output different vector sizes (nomic-embed-text =
    768, bge-m3 = 1024). sqlite-vec fixes the dimension at table creation, so a
    full reindex with a new model must first rebuild the table to the new size —
    otherwise every insert fails with a dimension mismatch. Called at the start
    of a full reindex, which rebuilds all vectors anyway.
    """
    dim = int(dim)
    if dim <= 0:
        raise ValueError(f"Invalid embedding dimension: {dim}")
    conn = _get_conn()
    conn.execute("DROP TABLE IF EXISTS bookmarks_vec")
    conn.execute(
        f"""
        CREATE VIRTUAL TABLE bookmarks_vec USING vec0(
            bookmark_id TEXT PRIMARY KEY,
            embedding   FLOAT[{dim}]
        )
        """
    )


def upsert(bookmark_id: str, vector: list[float]) -> None:
    """Store or replace the embedding for a bookmark."""
    if not vector:
        return
    try:
        import json
        conn = _get_conn()
        vec_json = json.dumps(vector)
        conn.execute(
            "DELETE FROM bookmarks_vec WHERE bookmark_id = ?", (bookmark_id,)
        )
        conn.execute(
            "INSERT INTO bookmarks_vec(bookmark_id, embedding) VALUES (?, ?)",
            (bookmark_id, vec_json),
        )
    except Exception as e:
        logger.warning("vector_store.upsert failed for %s: %s", bookmark_id, e)


def delete(bookmark_id: str) -> None:
    """Remove the embedding when a bookmark is trashed or deleted."""
    try:
        _get_conn().execute(
            "DELETE FROM bookmarks_vec WHERE bookmark_id = ?", (bookmark_id,)
        )
    except Exception as e:
        logger.warning("vector_store.delete failed for %s: %s", bookmark_id, e)


def search(query_vec: list[float], k: int = 20) -> list[tuple[str, float]]:
    """Return up to k (bookmark_id, distance) pairs, closest first."""
    import json
    try:
        rows = _get_conn().execute(
            """
            SELECT bookmark_id, distance
            FROM bookmarks_vec
            WHERE embedding MATCH ?
              AND k = ?
            ORDER BY distance
            """,
            (json.dumps(query_vec), k),
        ).fetchall()
        return [(row[0], row[1]) for row in rows]
    except Exception as e:
        logger.warning("vector_store.search failed: %s", e)
        return []


def count() -> int:
    """How many embeddings are stored (useful for diagnostics)."""
    try:
        row = _get_conn().execute(
            "SELECT count(*) FROM bookmarks_vec"
        ).fetchone()
        return row[0] if row else 0
    except Exception:
        return 0
