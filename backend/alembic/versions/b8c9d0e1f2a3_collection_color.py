"""Add color to collections

Revision ID: b8c9d0e1f2a3
Revises: a7b8c9d0e1f2
Create Date: 2026-05-31

Lets a folder carry an optional accent color (hex string), shown in the sidebar.
Plain ADD COLUMN — SQLite does it in place, no table rebuild.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "b8c9d0e1f2a3"
down_revision: Union[str, None] = "a7b8c9d0e1f2"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("collections", sa.Column("color", sa.String(), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("collections") as batch:
        batch.drop_column("color")
