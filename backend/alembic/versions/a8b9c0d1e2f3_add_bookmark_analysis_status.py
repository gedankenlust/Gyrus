"""persist bookmark enrichment status

Revision ID: a8b9c0d1e2f3
Revises: f7a8b9c0d1e2
Create Date: 2026-07-22 10:00:00.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "a8b9c0d1e2f3"
down_revision: Union[str, None] = "f7a8b9c0d1e2"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("bookmarks", sa.Column("metadata_status", sa.String(), nullable=False, server_default="pending"))
    op.add_column("bookmarks", sa.Column("reader_status", sa.String(), nullable=False, server_default="pending"))
    op.add_column("bookmarks", sa.Column("index_status", sa.String(), nullable=False, server_default="not_requested"))
    op.add_column("bookmarks", sa.Column("analysis_error", sa.Text(), nullable=True))
    op.add_column("bookmarks", sa.Column("analysis_attempts", sa.Integer(), nullable=False, server_default="0"))
    op.add_column("bookmarks", sa.Column("analysis_updated_at", sa.DateTime(), nullable=True))

    # Do not surprise-upgrade an existing library into a full recrawl.
    op.execute(
        """
        UPDATE bookmarks
        SET metadata_status = CASE
                WHEN description IS NOT NULL OR favicon_path IS NOT NULL OR og_image_url IS NOT NULL
                THEN 'ready' ELSE 'not_requested' END,
            reader_status = CASE
                WHEN scraped_content IS NOT NULL AND length(trim(scraped_content)) > 0
                THEN 'ready' ELSE 'not_requested' END,
            index_status = 'not_requested'
        """
    )


def downgrade() -> None:
    op.drop_column("bookmarks", "analysis_updated_at")
    op.drop_column("bookmarks", "analysis_attempts")
    op.drop_column("bookmarks", "analysis_error")
    op.drop_column("bookmarks", "index_status")
    op.drop_column("bookmarks", "reader_status")
    op.drop_column("bookmarks", "metadata_status")
