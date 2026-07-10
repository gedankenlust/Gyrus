"""add persistent AI Brain chat messages

Revision ID: d5e6f7a8b9c0
Revises: c4d5e6f7a8b9
Create Date: 2026-07-10 00:00:00.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "d5e6f7a8b9c0"
down_revision: Union[str, None] = "c4d5e6f7a8b9"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "brain_messages",
        sa.Column("id", sa.String(), nullable=False),
        sa.Column("bookmark_id", sa.String(), nullable=False),
        sa.Column("role", sa.String(), nullable=False),
        sa.Column("content", sa.Text(), nullable=False),
        sa.Column("model", sa.String(), nullable=True),
        sa.Column("status", sa.String(), nullable=False, server_default="complete"),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(["bookmark_id"], ["bookmarks.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_brain_messages_bookmark_id"), "brain_messages", ["bookmark_id"], unique=False)
    op.create_index(op.f("ix_brain_messages_created_at"), "brain_messages", ["created_at"], unique=False)


def downgrade() -> None:
    op.drop_index(op.f("ix_brain_messages_created_at"), table_name="brain_messages")
    op.drop_index(op.f("ix_brain_messages_bookmark_id"), table_name="brain_messages")
    op.drop_table("brain_messages")
