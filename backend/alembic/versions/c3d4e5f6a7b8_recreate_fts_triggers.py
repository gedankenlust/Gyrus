"""recreate fts triggers and rebuild index

Revision ID: c3d4e5f6a7b8
Revises: b2c3d4e5f6a7
Create Date: 2026-05-18

The screenshot-removal migration used op.batch_alter_table("bookmarks"),
which in SQLite recreates the table — and silently drops every trigger
bound to it, including the FTS sync triggers. Without them the search
index is never updated, so full-text search returns nothing. This
recreates the triggers and rebuilds the index from current content.

NOTE for future migrations: any batch_alter_table on "bookmarks" drops
these triggers again. Recreate them afterwards.
"""
from alembic import op

revision = "c3d4e5f6a7b8"
down_revision = "b2c3d4e5f6a7"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("DROP TRIGGER IF EXISTS bookmarks_ai")
    op.execute("DROP TRIGGER IF EXISTS bookmarks_ad")
    op.execute("DROP TRIGGER IF EXISTS bookmarks_au")
    op.execute("""
        CREATE TRIGGER bookmarks_ai AFTER INSERT ON bookmarks BEGIN
            INSERT INTO bookmarks_fts(rowid, id, title, url, description, notes)
            VALUES (new.rowid, new.id, new.title, new.url, new.description, new.notes);
        END
    """)
    op.execute("""
        CREATE TRIGGER bookmarks_ad AFTER DELETE ON bookmarks BEGIN
            INSERT INTO bookmarks_fts(bookmarks_fts, rowid, id, title, url, description, notes)
            VALUES ('delete', old.rowid, old.id, old.title, old.url, old.description, old.notes);
        END
    """)
    op.execute("""
        CREATE TRIGGER bookmarks_au AFTER UPDATE ON bookmarks BEGIN
            INSERT INTO bookmarks_fts(bookmarks_fts, rowid, id, title, url, description, notes)
            VALUES ('delete', old.rowid, old.id, old.title, old.url, old.description, old.notes);
            INSERT INTO bookmarks_fts(rowid, id, title, url, description, notes)
            VALUES (new.rowid, new.id, new.title, new.url, new.description, new.notes);
        END
    """)
    # Rebuild the index from the content table — entries inserted while the
    # triggers were missing are not in the index yet.
    op.execute("INSERT INTO bookmarks_fts(bookmarks_fts) VALUES('rebuild')")


def downgrade() -> None:
    pass
