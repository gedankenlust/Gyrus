"""Add manual sort order (position) to collections

Revision ID: a7b8c9d0e1f2
Revises: eba27958e920
Create Date: 2026-05-31

Adds a per-sibling `position` so folders can be reordered by drag & drop.
Existing folders are numbered within each parent group by creation time, so
the current (created_at) order is preserved as the initial manual order.

Plain ADD COLUMN — SQLite does this in place (no table rebuild), so no FTS
triggers are affected.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "a7b8c9d0e1f2"
down_revision: Union[str, None] = "eba27958e920"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "collections",
        sa.Column("position", sa.Integer(), nullable=False, server_default="0"),
    )
    # Backfill: number each parent group by created_at so the existing order sticks.
    conn = op.get_bind()
    rows = conn.execute(
        sa.text("SELECT id, parent_id FROM collections ORDER BY parent_id, created_at")
    ).fetchall()
    counters: dict[str, int] = {}
    for cid, parent_id in rows:
        key = parent_id or ""
        idx = counters.get(key, 0)
        conn.execute(
            sa.text("UPDATE collections SET position = :p WHERE id = :id"),
            {"p": idx, "id": cid},
        )
        counters[key] = idx + 1


def downgrade() -> None:
    with op.batch_alter_table("collections") as batch:
        batch.drop_column("position")
