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
import threading
import functools
import json

logger = logging.getLogger(__name__)

# Lazy singleton — the apsw connection is opened once on first use.
_conn = None
_lock = threading.RLock()
_invalid = False


def serialized(function):
    @functools.wraps(function)
    def call(*args, **kwargs):
        with _lock:
            return function(*args, **kwargs)
    return call


def _config(conn):
    conn.execute("CREATE TABLE IF NOT EXISTS gyrus_vector_config (id INTEGER PRIMARY KEY, model_key TEXT, valid INTEGER NOT NULL)")
    return conn.execute("SELECT model_key, valid FROM gyrus_vector_config WHERE id=1").fetchone()


def _set_config(conn, key, valid=True):
    _config(conn)
    conn.execute("INSERT OR REPLACE INTO gyrus_vector_config VALUES (1, ?, ?)", (key, int(valid)))


def invalidate_for_replacement(db):
    """Invalidate derived state in the same transaction as a library replacement."""
    from sqlalchemy import text
    db.execute(text("CREATE TABLE IF NOT EXISTS gyrus_vector_config (id INTEGER PRIMARY KEY, model_key TEXT, valid INTEGER NOT NULL)"))
    db.execute(text("INSERT OR REPLACE INTO gyrus_vector_config VALUES (1, NULL, 0)"))


@serialized
def matches_configuration(key):
    conn = _get_conn()
    row = _config(conn)
    if _invalid or (row and not row[1]):
        return False
    if not row or row[0] is None:
        return count() == 0
    return row[0] == key



@serialized
def _get_conn():
    global _conn
    if _conn is not None:
        return _conn

    import apsw
    import sqlite_vec
    from database import DB_PATH

    conn = apsw.Connection(str(DB_PATH))
    conn.setbusytimeout(5000)
    conn.enableloadextension(True)
    sqlite_vec.load(conn)
    conn.enableloadextension(False)
    _conn = conn
    return conn


@serialized
def reset_table(dim: int, model_key: str | None = None) -> None:
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
    global _invalid
    conn = _get_conn()
    with conn:
        conn.execute("DROP TABLE IF EXISTS bookmarks_vec")
        conn.execute(f"CREATE VIRTUAL TABLE bookmarks_vec USING vec0(bookmark_id TEXT PRIMARY KEY, embedding FLOAT[{dim}])")
        _set_config(conn, model_key)
    _invalid = False


@serialized
def upsert(bookmark_id: str, vector: list[float], *, model_key: str | None = None) -> bool:
    """Store or replace the embedding for a bookmark."""
    if not vector:
        return False
    try:
        import json
        conn = _get_conn()
        if model_key is not None:
            if not matches_configuration(model_key):
                return False
            if count() == 0:
                reset_table(len(vector), model_key)
        vec_json = json.dumps(vector)
        with conn:
            conn.execute("DELETE FROM bookmarks_vec WHERE bookmark_id = ?", (bookmark_id,))
            conn.execute("INSERT INTO bookmarks_vec(bookmark_id, embedding) VALUES (?, ?)", (bookmark_id, vec_json))
        return True
    except Exception as e:
        logger.warning("vector_store.upsert failed for %s: %s", bookmark_id, e)
        return False


@serialized
def delete(bookmark_id: str) -> None:
    """Remove the embedding when a bookmark is trashed or deleted."""
    try:
        _get_conn().execute(
            "DELETE FROM bookmarks_vec WHERE bookmark_id = ?", (bookmark_id,)
        )
    except Exception as e:
        logger.warning("vector_store.delete failed for %s: %s", bookmark_id, e)


@serialized
def delete_many(bookmark_ids: list[str]) -> None:
    """Remove embeddings in bulk when bookmarks are trashed or deleted.

    Batches the deletes using an IN clause to avoid excessive transaction overhead.
    """
    if not bookmark_ids:
        return
    try:
        conn = _get_conn()
        # Use chunks of 900 to stay well under SQLite's parameter limits
        chunk_size = 900
        for i in range(0, len(bookmark_ids), chunk_size):
            chunk = bookmark_ids[i:i + chunk_size]
            placeholders = ",".join(["?"] * len(chunk))
            conn.execute(
                f"DELETE FROM bookmarks_vec WHERE bookmark_id IN ({placeholders})", chunk
            )
    except Exception as e:
        logger.warning("vector_store.delete_many failed: %s", e)


@serialized
def clear(*, strict: bool = False) -> None:
    """Remove every embedding, including stale rows without a bookmark."""
    global _invalid
    try:
        conn = _get_conn()
        with conn:
            conn.execute("DELETE FROM bookmarks_vec")
            _set_config(conn, None)
        _invalid = False
    except Exception as e:
        _invalid = True
        logger.warning("vector_store.clear failed: %s", e)
        if strict:
            raise


def _parse_embedding(value):
    if value is None:
        return None
    if isinstance(value, str):
        parsed = json.loads(value)
        return [float(item) for item in parsed]
    if isinstance(value, (bytes, bytearray)):
        import struct
        width = len(value) // 4
        if width <= 0 or len(value) != width * 4:
            return None
        return list(struct.unpack(f"<{width}f", value))
    return [float(item) for item in value]


@serialized
def embedding_for(bookmark_id: str) -> list[float] | None:
    """Return the stored embedding for one bookmark, if the index has one."""
    try:
        row = _get_conn().execute(
            "SELECT embedding FROM bookmarks_vec WHERE bookmark_id = ?",
            (bookmark_id,),
        ).fetchone()
    except Exception as e:
        logger.warning("vector_store.embedding_for failed for %s: %s", bookmark_id, e)
        return None
    if not row or row[0] is None:
        return None
    try:
        return _parse_embedding(row[0])
    except (TypeError, ValueError, json.JSONDecodeError) as e:
        logger.warning("vector_store.embedding_for failed for %s: %s", bookmark_id, e)
        return None


@serialized
def all_embeddings() -> dict[str, list[float]]:
    """Every stored vector. Used by folder sorting so it does not call Ollama."""
    try:
        rows = _get_conn().execute("SELECT bookmark_id, embedding FROM bookmarks_vec").fetchall()
    except Exception as e:
        logger.warning("vector_store.all_embeddings failed: %s", e)
        return {}
    found = {}
    for bookmark_id, raw in rows:
        try:
            parsed = _parse_embedding(raw)
        except (TypeError, ValueError, json.JSONDecodeError):
            continue
        if parsed:
            found[bookmark_id] = parsed
    return found


@serialized
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


@serialized
def count() -> int:
    """How many embeddings are stored (useful for diagnostics)."""
    try:
        row = _get_conn().execute(
            "SELECT count(*) FROM bookmarks_vec"
        ).fetchone()
        return row[0] if row else 0
    except Exception:
        return 0


@serialized
def replace_all(rows, dimension, model_key):
    """Commit a fully computed replacement atomically; rollback retains old vectors."""
    global _invalid
    conn = _get_conn()
    with conn:
        conn.execute("DROP TABLE IF EXISTS bookmarks_vec")
        conn.execute(f"CREATE VIRTUAL TABLE bookmarks_vec USING vec0(bookmark_id TEXT PRIMARY KEY, embedding FLOAT[{int(dimension)}])")
        for ident, vector in rows:
            conn.execute("INSERT INTO bookmarks_vec VALUES (?, ?)", (ident, json.dumps(vector)))
        _set_config(conn, model_key)
    _invalid = False
