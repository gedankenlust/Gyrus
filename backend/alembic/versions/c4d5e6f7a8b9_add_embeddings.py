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
    # sqlite-vec requires the extension to be loaded. Apple's Python builds
    # don't expose enable_load_extension on sqlite3.Connection, so we open a
    # second apsw connection to the same file just for this DDL statement.
    import apsw
    import sqlite_vec
    from database import DB_PATH

    conn = apsw.Connection(str(DB_PATH))
    conn.enableloadextension(True)
    sqlite_vec.load(conn)
    conn.enableloadextension(False)
    conn.execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS bookmarks_vec
        USING vec0(
            bookmark_id TEXT PRIMARY KEY,
            embedding   FLOAT[768]
        )
    """)


def downgrade() -> None:
    op.execute("DROP TABLE IF EXISTS bookmarks_vec")
