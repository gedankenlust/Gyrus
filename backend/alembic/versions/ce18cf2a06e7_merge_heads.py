"""merge_heads

Revision ID: ce18cf2a06e7
Revises: 68c04fed6ffb, b8c9d0e1f2a3
Create Date: 2026-06-04 22:55:30.336752

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'ce18cf2a06e7'
down_revision: Union[str, None] = ('68c04fed6ffb', 'b8c9d0e1f2a3')
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    pass


def downgrade() -> None:
    pass
