"""index scraped page content for full-text search

Adds bookmarks.scraped_content and rebuilds the FTS5 table + triggers so the
extracted article text is searchable alongside title/url/description/notes.

Revision ID: b3c4d5e6f7a8
Revises: a2b3c4d5e6f7
Create Date: 2026-06-09 00:20:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'b3c4d5e6f7a8'
down_revision: Union[str, None] = 'a2b3c4d5e6f7'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _create_fts(columns: str, col_list: str) -> None:
    """(Re)create the external-content FTS5 table + sync triggers.

    `columns` is the fts5() column declaration; `col_list` is the shared column
    list used by the triggers (must match, minus the rowid)."""
    op.execute("DROP TRIGGER IF EXISTS bookmarks_ai")
    op.execute("DROP TRIGGER IF EXISTS bookmarks_ad")
    op.execute("DROP TRIGGER IF EXISTS bookmarks_au")
    op.execute("DROP TABLE IF EXISTS bookmarks_fts")
    op.execute(
        f"CREATE VIRTUAL TABLE bookmarks_fts USING fts5("
        f"{columns}, content='bookmarks', content_rowid='rowid')"
    )
    new_vals = ", ".join("new." + c.strip() for c in col_list.split(","))
    old_vals = ", ".join("old." + c.strip() for c in col_list.split(","))
    op.execute(f"""
        CREATE TRIGGER bookmarks_ai AFTER INSERT ON bookmarks BEGIN
            INSERT INTO bookmarks_fts(rowid, {col_list})
            VALUES (new.rowid, {new_vals});
        END
    """)
    op.execute(f"""
        CREATE TRIGGER bookmarks_ad AFTER DELETE ON bookmarks BEGIN
            INSERT INTO bookmarks_fts(bookmarks_fts, rowid, {col_list})
            VALUES ('delete', old.rowid, {old_vals});
        END
    """)
    op.execute(f"""
        CREATE TRIGGER bookmarks_au AFTER UPDATE ON bookmarks BEGIN
            INSERT INTO bookmarks_fts(bookmarks_fts, rowid, {col_list})
            VALUES ('delete', old.rowid, {old_vals});
            INSERT INTO bookmarks_fts(rowid, {col_list})
            VALUES (new.rowid, {new_vals});
        END
    """)
    op.execute("INSERT INTO bookmarks_fts(bookmarks_fts) VALUES('rebuild')")


def upgrade() -> None:
    op.add_column("bookmarks", sa.Column("scraped_content", sa.Text(), nullable=True))
    _create_fts(
        "id UNINDEXED, title, url, description, notes, scraped_content",
        "id, title, url, description, notes, scraped_content",
    )


def downgrade() -> None:
    _create_fts(
        "id UNINDEXED, title, url, description, notes",
        "id, title, url, description, notes",
    )
    op.drop_column("bookmarks", "scraped_content")
