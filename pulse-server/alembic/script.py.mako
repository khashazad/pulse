"""${message}

Revision ID: ${up_revision}
Revises: ${down_revision | comma,n}
Create Date: ${create_date}
"""
from __future__ import annotations

from alembic import op
import sqlalchemy as sa
${imports if imports else ""}

# revision identifiers, used by Alembic.
revision = ${repr(up_revision)}
down_revision = ${repr(down_revision)}
branch_labels = ${repr(branch_labels)}
depends_on = ${repr(depends_on)}


# Summary: Applies forward migration steps generated for this revision.
# Parameters:
# - None: Uses Alembic operations context bound to current migration transaction.
# Returns:
# - None: Executes schema changes required for this revision.
# Raises/Throws:
# - sqlalchemy.exc.SQLAlchemyError: Raised when migration DDL execution fails.
def upgrade() -> None:
    ${upgrades if upgrades else "pass"}


# Summary: Reverts migration steps generated for this revision.
# Parameters:
# - None: Uses Alembic operations context bound to current migration transaction.
# Returns:
# - None: Executes schema rollback changes for this revision.
# Raises/Throws:
# - sqlalchemy.exc.SQLAlchemyError: Raised when rollback DDL execution fails.
def downgrade() -> None:
    ${downgrades if downgrades else "pass"}
