"""Add structured notes

Revision ID: eba27958e920
Revises: c3d4e5f6a7b8
Create Date: 2026-05-30 00:21:11.072651

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'eba27958e920'
down_revision: Union[str, None] = 'c3d4e5f6a7b8'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 1. Create the new table
    op.create_table('bookmark_notes',
    sa.Column('id', sa.String(), nullable=False),
    sa.Column('bookmark_id', sa.String(), nullable=False),
    sa.Column('content', sa.Text(), nullable=False),
    sa.Column('source', sa.String(), nullable=False, server_default='user'),
    sa.Column('created_at', sa.DateTime(), nullable=False),
    sa.Column('updated_at', sa.DateTime(), nullable=False),
    sa.ForeignKeyConstraint(['bookmark_id'], ['bookmarks.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index(op.f('ix_bookmark_notes_bookmark_id'), 'bookmark_notes', ['bookmark_id'], unique=False)
    
    # 2. Data Migration: Copy existing notes to bookmark_notes
    import uuid
    from datetime import datetime, timezone
    connection = op.get_bind()
    results = connection.execute(sa.text("SELECT id, notes FROM bookmarks WHERE notes IS NOT NULL AND notes != ''")).fetchall()
    
    for row in results:
        bm_id = row[0]
        content = row[1]
        note_id = str(uuid.uuid4())
        now = datetime.now(timezone.utc)
        connection.execute(
            sa.text("INSERT INTO bookmark_notes (id, bookmark_id, content, source, created_at, updated_at) VALUES (:id, :bm_id, :content, :source, :now, :now)"),
            {"id": note_id, "bm_id": bm_id, "content": content, "source": "user", "now": now}
        )

def downgrade() -> None:
    op.drop_index(op.f('ix_bookmark_notes_bookmark_id'), table_name='bookmark_notes')
    op.drop_table('bookmark_notes')
