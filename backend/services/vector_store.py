"""SQLite-vec vector store for semantic search.

The vectors live in their own database file (database.VECTOR_DB_PATH), opened
only here and only through apsw, the one Python SQLite adapter that can load
extensions on every Mac build. The library itself (gyrus.db) is opened only by
Python's sqlite3 through SQLAlchemy.

Two SQLite libraries must never open the same file in one process. POSIX locks
do not tell them apart, so a closing apsw connection once took itself for the
last user of gyrus.db and deleted the -wal and -shm files that sqlite3 was still
writing to. And sqlite-vec keeps one global pointer to the library that loaded
it last, so it may be loaded into apsw only.

What stays in gyrus.db is a plain flag table, gyrus_vector_config, which a
library replacement clears in its own transaction (invalidate_for_replacement).
The model the vectors belong to is stored next to them in vector_config.

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

_LIBRARY_STATE_TABLE = (
    "CREATE TABLE IF NOT EXISTS gyrus_vector_config "
    "(id INTEGER PRIMARY KEY, model_key TEXT, valid INTEGER NOT NULL)"
)


def serialized(function):
    @functools.wraps(function)
    def call(*args, **kwargs):
        with _lock:
            return function(*args, **kwargs)
    return call


# --- State kept in the library database (sqlite3 / SQLAlchemy only) --------

def invalidate_for_replacement(db):
    """Invalidate derived state in the same transaction as a library replacement."""
    from sqlalchemy import text
    db.execute(text(_LIBRARY_STATE_TABLE))
    db.execute(text("INSERT OR REPLACE INTO gyrus_vector_config VALUES (1, NULL, 0)"))


def _library_valid() -> bool:
    """False while a library replacement has invalidated the vectors."""
    from sqlalchemy import text
    from sqlalchemy.exc import OperationalError
    from database import engine
    try:
        with engine.connect() as connection:
            row = connection.execute(text("SELECT valid FROM gyrus_vector_config WHERE id=1")).fetchone()
    except OperationalError:
        # No table yet: nothing has ever invalidated the vectors.
        return True
    return row is None or bool(row[0])


def _mark_library_valid() -> None:
    """Called after the vectors were rebuilt or cleared, outside _lock: it may
    wait for the library's write lock, which a request holding that lock could
    otherwise hold against a vector delete it is waiting for."""
    from sqlalchemy import text
    from database import engine
    with engine.begin() as connection:
        connection.execute(text(_LIBRARY_STATE_TABLE))
        connection.execute(text("INSERT OR REPLACE INTO gyrus_vector_config VALUES (1, NULL, 1)"))


# --- The vector database (apsw only) ---------------------------------------

def _vector_key(conn):
    conn.execute("CREATE TABLE IF NOT EXISTS vector_config (id INTEGER PRIMARY KEY, model_key TEXT)")
    row = conn.execute("SELECT model_key FROM vector_config WHERE id=1").fetchone()
    return row[0] if row else None


def _set_vector_key(conn, key):
    conn.execute("CREATE TABLE IF NOT EXISTS vector_config (id INTEGER PRIMARY KEY, model_key TEXT)")
    conn.execute("INSERT OR REPLACE INTO vector_config VALUES (1, ?)", (key,))


@serialized
def matches_configuration(key):
    if _invalid or not _library_valid():
        return False
    stored = _vector_key(_get_conn())
    if stored is None:
        return count() == 0
    return stored == key


@serialized
def _get_conn():
    global _conn
    if _conn is not None:
        return _conn

    import apsw
    import sqlite_vec
    from database import VECTOR_DB_PATH

    VECTOR_DB_PATH.touch(mode=0o600, exist_ok=True)
    VECTOR_DB_PATH.chmod(0o600)
    conn = apsw.Connection(str(VECTOR_DB_PATH))
    conn.setbusytimeout(5000)
    conn.enableloadextension(True)
    sqlite_vec.load(conn)
    conn.enableloadextension(False)
    conn.execute(
        "CREATE VIRTUAL TABLE IF NOT EXISTS bookmarks_vec "
        "USING vec0(bookmark_id TEXT PRIMARY KEY, embedding FLOAT[768])"
    )
    _conn = conn
    return conn


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
    _rebuild(dim, model_key)
    _mark_library_valid()


@serialized
def _rebuild(dim: int, model_key: str | None) -> None:
    global _invalid
    conn = _get_conn()
    with conn:
        conn.execute("DROP TABLE IF EXISTS bookmarks_vec")
        conn.execute(f"CREATE VIRTUAL TABLE bookmarks_vec USING vec0(bookmark_id TEXT PRIMARY KEY, embedding FLOAT[{dim}])")
        _set_vector_key(conn, model_key)
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
                # The library flag was just found valid; only the vectors
                # need rebuilding, without taking the library's write lock.
                _rebuild(len(vector), model_key)
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


def clear(*, strict: bool = False) -> None:
    """Remove every embedding, including stale rows without a bookmark."""
    global _invalid
    try:
        with _lock:
            conn = _get_conn()
            with conn:
                conn.execute("DELETE FROM bookmarks_vec")
                _set_vector_key(conn, None)
        _mark_library_valid()
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


def replace_all(rows, dimension, model_key):
    """Commit a fully computed replacement atomically; rollback retains old vectors."""
    global _invalid
    with _lock:
        conn = _get_conn()
        with conn:
            conn.execute("DROP TABLE IF EXISTS bookmarks_vec")
            conn.execute(f"CREATE VIRTUAL TABLE bookmarks_vec USING vec0(bookmark_id TEXT PRIMARY KEY, embedding FLOAT[{int(dimension)}])")
            for ident, vector in rows:
                conn.execute("INSERT INTO bookmarks_vec VALUES (?, ?)", (ident, json.dumps(vector)))
            _set_vector_key(conn, model_key)
        _invalid = False
    _mark_library_valid()
