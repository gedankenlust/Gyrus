"""Move semantic-search vectors out of the library database, once.

Until this release the vectors lived in a sqlite-vec table inside gyrus.db,
next to the library that Python's sqlite3 manages. Two SQLite libraries must
not share a file in one process (see services.vector_store), so the vectors
now live in vectors.db, and an existing library has to hand its table over.

Reading that table needs sqlite-vec, which may only be loaded into apsw, and
apsw must not open gyrus.db inside the backend process. So the backend runs
this module as a child process (relocate_in_child). Between two processes the
operating system's file locks work as SQLite expects.

Each step commits on its own and is safe to repeat: the vectors are copied
only while vectors.db has none, and the old table is dropped afterwards.
"""
import logging
import re
import subprocess
import sys
from pathlib import Path

logger = logging.getLogger(__name__)

BACKEND_DIR = Path(__file__).resolve().parents[1]


def has_legacy_table(engine) -> bool:
    """Whether gyrus.db still holds the old vector table. Reads only the
    schema, which sqlite3 can do without sqlite-vec."""
    from sqlalchemy import text
    with engine.connect() as connection:
        row = connection.execute(
            text("SELECT 1 FROM sqlite_master WHERE type='table' AND name='bookmarks_vec'")
        ).fetchone()
    return row is not None


def relocate_in_child(library_path: Path, vectors_path: Path, timeout: float = 300) -> bool:
    """Run relocate() in a separate interpreter. True when it succeeded."""
    result = subprocess.run(
        [sys.executable, "-m", "services.vector_relocation", str(library_path), str(vectors_path)],
        cwd=BACKEND_DIR,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if result.returncode != 0:
        logger.warning("Moving the semantic-search vectors failed: %s", result.stderr.strip()[-2000:])
        return False
    return True


def relocate(library_path: str, vectors_path: str) -> int:
    """Copy the old table into vectors.db unless it already has vectors, then
    drop it from gyrus.db. Returns how many vectors were copied."""
    import apsw
    import sqlite_vec

    Path(vectors_path).touch(mode=0o600, exist_ok=True)
    Path(vectors_path).chmod(0o600)
    conn = apsw.Connection(vectors_path)
    conn.setbusytimeout(10_000)
    conn.enableloadextension(True)
    sqlite_vec.load(conn)
    conn.enableloadextension(False)
    conn.execute("ATTACH DATABASE ? AS library", (library_path,))
    try:
        row = conn.execute(
            "SELECT sql FROM library.sqlite_master WHERE type='table' AND name='bookmarks_vec'"
        ).fetchone()
        if row is None:
            return 0

        existing = conn.execute(
            "SELECT count(*) FROM main.sqlite_master WHERE type='table' AND name='bookmarks_vec'"
        ).fetchone()[0]
        copied = 0
        if not existing or not conn.execute("SELECT count(*) FROM main.bookmarks_vec").fetchone()[0]:
            match = re.search(r"FLOAT\[(\d+)\]", row[0], re.IGNORECASE)
            dimension = int(match.group(1)) if match else 768
            key = _legacy_model_key(conn)
            with conn:
                conn.execute("DROP TABLE IF EXISTS main.bookmarks_vec")
                conn.execute(
                    "CREATE VIRTUAL TABLE main.bookmarks_vec USING "
                    f"vec0(bookmark_id TEXT PRIMARY KEY, embedding FLOAT[{dimension}])"
                )
                conn.execute(
                    "INSERT INTO main.bookmarks_vec(bookmark_id, embedding) "
                    "SELECT bookmark_id, embedding FROM library.bookmarks_vec"
                )
                copied = conn.execute("SELECT count(*) FROM main.bookmarks_vec").fetchone()[0]
                conn.execute("CREATE TABLE IF NOT EXISTS main.vector_config (id INTEGER PRIMARY KEY, model_key TEXT)")
                conn.execute("INSERT OR REPLACE INTO main.vector_config VALUES (1, ?)", (key,))

        # Its own transaction: a separate commit in each file. Should the drop
        # not happen, the next start finds vectors here and only drops.
        with conn:
            conn.execute("DROP TABLE library.bookmarks_vec")
        return copied
    finally:
        conn.close()


def _legacy_model_key(conn):
    """The model the old vectors were built with, from gyrus_vector_config."""
    table = conn.execute(
        "SELECT 1 FROM library.sqlite_master WHERE type='table' AND name='gyrus_vector_config'"
    ).fetchone()
    if table is None:
        return None
    row = conn.execute("SELECT model_key FROM library.gyrus_vector_config WHERE id=1").fetchone()
    return row[0] if row else None


if __name__ == "__main__":
    library, vectors = sys.argv[1], sys.argv[2]
    print(relocate(library, vectors))
