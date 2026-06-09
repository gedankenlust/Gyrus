"""add is_read flag to bookmarks (read-later status)

Revision ID: f1a2b3c4d5e6
Revises: ce18cf2a06e7
Create Date: 2026-06-09 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'f1a2b3c4d5e6'
down_revision: Union[str, None] = 'ce18cf2a06e7'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Existing bookmarks default to unread (0) so nothing changes for current data.
    op.add_column(
        "bookmarks",
        sa.Column("is_read", sa.Boolean(), nullable=False, server_default="0"),
    )


def downgrade() -> None:
    op.drop_column("bookmarks", "is_read")
