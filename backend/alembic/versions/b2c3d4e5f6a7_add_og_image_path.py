"""add og_image_path

Revision ID: b2c3d4e5f6a7
Revises: a1b2c3d4e5f6
Create Date: 2026-05-16

"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy import inspect

revision = "b2c3d4e5f6a7"
down_revision = "a1b2c3d4e5f6"
branch_labels = None
depends_on = None


def _column_exists(table: str, column: str) -> bool:
    bind = op.get_bind()
    return column in [col["name"] for col in inspect(bind).get_columns(table)]


def upgrade() -> None:
    if not _column_exists("bookmarks", "og_image_path"):
        with op.batch_alter_table("bookmarks") as batch_op:
            batch_op.add_column(sa.Column("og_image_path", sa.String(), nullable=True))


def downgrade() -> None:
    if _column_exists("bookmarks", "og_image_path"):
        with op.batch_alter_table("bookmarks") as batch_op:
            batch_op.drop_column("og_image_path")
