"""The vectors live in their own file, and only apsw ever opens it.

Two SQLite libraries in one process must never share a database file: a
closing apsw connection once deleted the -wal and -shm files of the library's
sqlite3 connections, and sqlite-vec loaded into both crashed the process.
"""
import subprocess
import sys
import textwrap

import apsw
import pytest
import sqlite_vec
from sqlalchemy import create_engine, text

from database import DB_PATH, VECTOR_DB_PATH, SessionLocal
from services import vector_relocation, vector_store

# Builds a library the way releases before the split left it: the vector table
# inside gyrus.db next to ordinary tables. Run in a child process so that this
# test process never opens one file with both libraries.
LEGACY_LIBRARY = textwrap.dedent("""
    import sys, json, apsw, sqlite_vec
    conn = apsw.Connection(sys.argv[1])
    conn.enableloadextension(True)
    sqlite_vec.load(conn)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("CREATE TABLE bookmarks (id TEXT PRIMARY KEY, title TEXT)")
    conn.execute("INSERT INTO bookmarks VALUES ('a', 'Kept')")
    conn.execute("CREATE TABLE gyrus_vector_config (id INTEGER PRIMARY KEY, model_key TEXT, valid INTEGER NOT NULL)")
    conn.execute("INSERT INTO gyrus_vector_config VALUES (1, 'model-a', 1)")
    conn.execute("CREATE VIRTUAL TABLE bookmarks_vec USING vec0(bookmark_id TEXT PRIMARY KEY, embedding FLOAT[3])")
    conn.execute("INSERT INTO bookmarks_vec VALUES ('a', ?)", (json.dumps([1.0, 0.0, 0.0]),))
    conn.execute("INSERT INTO bookmarks_vec VALUES ('b', ?)", (json.dumps([0.0, 1.0, 0.0]),))
    conn.close()
""")


def _legacy_library(path):
    subprocess.run([sys.executable, "-c", LEGACY_LIBRARY, str(path)], check=True, timeout=60)


def _vectors(path):
    conn = apsw.Connection(str(path))
    conn.enableloadextension(True)
    sqlite_vec.load(conn)
    try:
        rows = conn.execute("SELECT bookmark_id FROM bookmarks_vec ORDER BY bookmark_id").fetchall()
        key = conn.execute("SELECT model_key FROM vector_config WHERE id=1").fetchone()
        nearest = conn.execute(
            "SELECT bookmark_id FROM bookmarks_vec WHERE embedding MATCH ? AND k = 1",
            ("[0.0, 1.0, 0.0]",),
        ).fetchone()
        return [row[0] for row in rows], key[0] if key else None, nearest[0]
    finally:
        conn.close()


def _library_tables(path):
    engine = create_engine(f"sqlite:///{path}")
    try:
        with engine.connect() as connection:
            return {row[0] for row in connection.execute(text("SELECT name FROM sqlite_master WHERE type='table'"))}
    finally:
        engine.dispose()


def test_existing_vectors_move_to_their_own_file_and_keep_their_model(tmp_path):
    library, vectors = tmp_path / "gyrus.db", tmp_path / "vectors.db"
    _legacy_library(library)
    engine = create_engine(f"sqlite:///{library}")
    try:
        assert vector_relocation.has_legacy_table(engine)
        assert vector_relocation.relocate_in_child(library, vectors)
        assert not vector_relocation.has_legacy_table(engine)
    finally:
        engine.dispose()

    assert _vectors(vectors) == (["a", "b"], "model-a", "b")
    tables = _library_tables(library)
    assert "bookmarks" in tables and "gyrus_vector_config" in tables
    assert not any(name.startswith("bookmarks_vec") for name in tables)
    assert vectors.stat().st_mode & 0o777 == 0o600

    # A second run has nothing left to do and changes nothing.
    assert vector_relocation.relocate_in_child(library, vectors)
    assert _vectors(vectors) == (["a", "b"], "model-a", "b")


def test_an_interrupted_move_keeps_the_vectors_already_copied(tmp_path):
    """If the old table survived a copy (the drop is a separate commit), the
    next start must not overwrite what vectors.db holds by then."""
    library, vectors = tmp_path / "gyrus.db", tmp_path / "vectors.db"
    _legacy_library(library)
    conn = apsw.Connection(str(vectors))
    conn.enableloadextension(True)
    sqlite_vec.load(conn)
    conn.execute("CREATE VIRTUAL TABLE bookmarks_vec USING vec0(bookmark_id TEXT PRIMARY KEY, embedding FLOAT[3])")
    conn.execute("INSERT INTO bookmarks_vec VALUES ('newer', '[0.0, 1.0, 0.0]')")
    conn.execute("CREATE TABLE vector_config (id INTEGER PRIMARY KEY, model_key TEXT)")
    conn.execute("INSERT INTO vector_config VALUES (1, 'model-b')")
    conn.close()

    assert vector_relocation.relocate_in_child(library, vectors)
    assert _vectors(vectors) == (["newer"], "model-b", "newer")
    assert not any(name.startswith("bookmarks_vec") for name in _library_tables(library))


def test_the_vector_store_never_opens_the_library_file(monkeypatch):
    opened = []
    real = apsw.Connection

    def recording(path, *args, **kwargs):
        opened.append(str(path))
        return real(path, *args, **kwargs)

    monkeypatch.setattr(apsw, "Connection", recording)
    monkeypatch.setattr(vector_store, "_conn", None)
    try:
        vector_store.reset_table(3, "model-a")
        assert vector_store.upsert("x", [0.1, 0.2, 0.3], model_key="model-a")
        assert vector_store.search([0.1, 0.2, 0.3])[0][0] == "x"
        vector_store.clear()
    finally:
        if vector_store._conn is not None:
            vector_store._conn.close()
    monkeypatch.undo()
    vector_store.reset_table(768)

    assert opened == [str(VECTOR_DB_PATH)]
    assert not any(name.startswith("bookmarks_vec") for name in _library_tables(DB_PATH))


def test_a_library_replacement_still_invalidates_the_vectors():
    vector_store.reset_table(3, "model-a")
    assert vector_store.upsert("x", [0.1, 0.2, 0.3], model_key="model-a")
    assert vector_store.matches_configuration("model-a")

    with SessionLocal() as db:
        vector_store.invalidate_for_replacement(db)
        db.rollback()
    assert vector_store.matches_configuration("model-a"), "a rolled-back replacement changes nothing"

    with SessionLocal() as db:
        vector_store.invalidate_for_replacement(db)
        db.commit()
    assert not vector_store.matches_configuration("model-a")
    assert not vector_store.upsert("y", [0.1, 0.2, 0.3], model_key="model-a")

    vector_store.clear()
    assert vector_store.count() == 0
    assert vector_store.matches_configuration("model-a"), "an empty, cleared index accepts any model"
    vector_store.reset_table(768)


@pytest.mark.parametrize("dimension", [3, 1024])
def test_reset_keeps_the_dimension(dimension):
    vector_store.reset_table(dimension, "model-a")
    assert vector_store.upsert("x", [0.5] * dimension, model_key="model-a")
    assert vector_store.count() == 1
    vector_store.reset_table(768)
