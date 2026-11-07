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


def upgrade() -> None:
    # Intentionally empty: services.vector_store creates the table through its
    # own long-lived apsw connection the first time it is used, and nothing
    # else reads it.
    #
    # The migration must not reach sqlite-vec itself. It first opened a second
    # SQLite library (apsw) on the file and dropped it: POSIX locks do not
    # separate two libraries in one process, so when the garbage collector
    # closed that connection it took itself for the last one and deleted the
    # -wal and -shm files the app's connections were still writing to. On a
    # fresh database everything written afterwards, this migration's version
    # stamp included, was lost when the backend stopped. Loading the extension
    # into Python's sqlite3 instead is no better: sqlite-vec keeps one global
    # pointer to the SQLite library that loaded it last, so the vector store's
    # apsw connection then calls into the wrong library and crashes.
    pass


def downgrade() -> None:
    op.execute("DROP TABLE IF EXISTS bookmarks_vec")
