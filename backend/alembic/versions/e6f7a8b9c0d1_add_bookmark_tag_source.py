"""track whether bookmark tags were assigned manually or by AI

Revision ID: e6f7a8b9c0d1
Revises: d5e6f7a8b9c0
Create Date: 2026-07-13 15:00:00.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "e6f7a8b9c0d1"
down_revision: Union[str, None] = "d5e6f7a8b9c0"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Existing relationships may include manual and historical AI assignments,
    # so preserve them as manual. Only future AI runs are replaceable safely.
    op.add_column(
        "bookmark_tags",
        sa.Column("source", sa.String(), nullable=False, server_default="manual"),
    )


def downgrade() -> None:
    op.drop_column("bookmark_tags", "source")
