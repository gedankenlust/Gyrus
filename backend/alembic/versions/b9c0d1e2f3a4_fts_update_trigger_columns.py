"""limit the FTS update trigger to indexed columns

Revision ID: b9c0d1e2f3a4
Revises: a8b9c0d1e2f3
Create Date: 2026-11-07 10:00:00.000000

bookmarks_au fired on every UPDATE of bookmarks, so each is_read toggle,
deleted_at change, link-check result or enrichment status transition deleted
and re-inserted the row's FTS entry, re-tokenizing the full scraped page text.
The body is unchanged; only the columns that feed bookmarks_fts (id is listed
for strict equivalence, it never changes) now trigger a reindex.

NOTE for future migrations: any batch_alter_table on "bookmarks" drops these
triggers. Recreate them afterwards.
"""
from typing import Sequence, Union

from alembic import op


revision: str = "b9c0d1e2f3a4"
down_revision: Union[str, None] = "a8b9c0d1e2f3"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

_COLUMNS = "id, title, url, description, notes, scraped_content"
_NEW = ", ".join(f"new.{column.strip()}" for column in _COLUMNS.split(","))
_OLD = ", ".join(f"old.{column.strip()}" for column in _COLUMNS.split(","))
_BODY = f"""
    INSERT INTO bookmarks_fts(bookmarks_fts, rowid, {_COLUMNS})
    VALUES ('delete', old.rowid, {_OLD});
    INSERT INTO bookmarks_fts(rowid, {_COLUMNS})
    VALUES (new.rowid, {_NEW});
"""


def upgrade() -> None:
    op.execute("DROP TRIGGER IF EXISTS bookmarks_au")
    op.execute(
        f"CREATE TRIGGER bookmarks_au AFTER UPDATE OF {_COLUMNS} ON bookmarks BEGIN"
        f"{_BODY}END"
    )


def downgrade() -> None:
    op.execute("DROP TRIGGER IF EXISTS bookmarks_au")
    op.execute(f"CREATE TRIGGER bookmarks_au AFTER UPDATE ON bookmarks BEGIN{_BODY}END")
