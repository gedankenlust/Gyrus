"""add bookmarks_vec virtual table for semantic search

Uses sqlite-vec's vec0 virtual table to store one 768-float embedding per
bookmark. The dimension matches nomic-embed-text; if the user switches to a
different model the table is rebuilt automatically.

Revision ID: c4d5e6f7a8b9
Revises: b3c4d5e6f7a8
Create Date: 2026-06-11 00:00:00.000000
"""
from typing import Sequence, Union
from alembic import op


revision: str = 'c4d5e6f7a8b9'
down_revision: Union[str, None] = 'b3c4d5e6f7a8'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


CREATE_TABLE = """
    CREATE VIRTUAL TABLE IF NOT EXISTS bookmarks_vec
    USING vec0(
        bookmark_id TEXT PRIMARY KEY,
        embedding   FLOAT[768]
    )
"""


def upgrade() -> None:
    # Only ever the migration's own connection. This used to open a second
    # SQLite library (apsw) on the file and drop it: POSIX locks do not
    # separate two libraries in one process, so when the garbage collector
    # closed that connection it took itself for the last one and deleted the
    # -wal and -shm files the app's connections were still writing to. On a
    # fresh database everything written afterwards, this migration's version
    # stamp included, was lost when the backend stopped, so the migrations ran
    # again on every launch and the library never kept anything.
    raw = op.get_bind().connection.driver_connection
    if not hasattr(raw, "enable_load_extension"):
        # Apple's and python.org's builds (development venvs) cannot load
        # extensions; services.vector_store creates the table through its own
        # long-lived apsw connection the first time it is used.
        return

    import sqlite_vec

    raw.enable_load_extension(True)
    try:
        sqlite_vec.load(raw)
    finally:
        raw.enable_load_extension(False)
    op.execute(CREATE_TABLE)


def downgrade() -> None:
    op.execute("DROP TABLE IF EXISTS bookmarks_vec")
