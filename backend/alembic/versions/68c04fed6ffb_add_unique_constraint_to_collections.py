"""add_unique_constraint_to_collections

Revision ID: 68c04fed6ffb
Revises: b8c9d0e1f2a3
Create Date: 2026-06-04 22:45:08.669560

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '68c04fed6ffb'
down_revision: Union[str, None] = 'eba27958e920'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Use a unique index that treats NULL as a value for uniqueness (by using IFNULL)
    # This prevents multiple collections with same name in same folder, including root.
    op.execute("CREATE UNIQUE INDEX idx_collection_name_parent_unique ON collections(name, IFNULL(parent_id, 'root'))")


def downgrade() -> None:
    op.execute("DROP INDEX idx_collection_name_parent_unique")
