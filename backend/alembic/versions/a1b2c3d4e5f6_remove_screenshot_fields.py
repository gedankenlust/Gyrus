"""remove screenshot fields

Revision ID: a1b2c3d4e5f6
Revises: e0d78211f111
Create Date: 2026-05-16

"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy import inspect

revision = "a1b2c3d4e5f6"
down_revision = "e0d78211f111"
branch_labels = None
depends_on = None


def _column_exists(table: str, column: str) -> bool:
    bind = op.get_bind()
    return column in [col["name"] for col in inspect(bind).get_columns(table)]


def upgrade() -> None:
    with op.batch_alter_table("bookmarks") as batch_op:
        if _column_exists("bookmarks", "screenshot_path"):
            batch_op.drop_column("screenshot_path")
        if _column_exists("bookmarks", "screenshot_status"):
            batch_op.drop_column("screenshot_status")


def downgrade() -> None:
    with op.batch_alter_table("bookmarks") as batch_op:
        if not _column_exists("bookmarks", "screenshot_status"):
            batch_op.add_column(sa.Column("screenshot_status", sa.String(), nullable=False, server_default="pending"))
        if not _column_exists("bookmarks", "screenshot_path"):
            batch_op.add_column(sa.Column("screenshot_path", sa.String(), nullable=True))
