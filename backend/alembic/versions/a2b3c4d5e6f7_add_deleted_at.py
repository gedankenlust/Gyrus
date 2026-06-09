"""add deleted_at to bookmarks (soft-delete / trash)

Revision ID: a2b3c4d5e6f7
Revises: f1a2b3c4d5e6
Create Date: 2026-06-09 00:10:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'a2b3c4d5e6f7'
down_revision: Union[str, None] = 'f1a2b3c4d5e6'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("bookmarks", sa.Column("deleted_at", sa.DateTime(), nullable=True))
    op.create_index("ix_bookmarks_deleted_at", "bookmarks", ["deleted_at"])


def downgrade() -> None:
    op.drop_index("ix_bookmarks_deleted_at", table_name="bookmarks")
    op.drop_column("bookmarks", "deleted_at")
