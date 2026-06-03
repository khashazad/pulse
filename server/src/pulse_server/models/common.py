"""Shared macro DTOs reused across multiple feature modules.

Defines :class:`MacroTotals` (a four-field calories/protein/carbs/fat
container used everywhere totals are reported) and :class:`MacroTargets`
(the user's daily nutrition goals plus optional target weight). These
types are imported by entries, summaries, logs, and meal responses; this
file is the canonical home for the macro vocabulary used on the wire.
"""

from __future__ import annotations

from decimal import ROUND_HALF_EVEN, Decimal

from pydantic import BaseModel, Field, field_validator


class MacroFields(BaseModel):
    """Shared, non-negative macro inputs (calories + protein/carbs/fat grams).

    Base for request/response DTOs that carry a single food's required macros
    with a ``ge=0`` floor on every value. Subclasses inherit these four fields
    unchanged; because Pydantic places base-class fields first in field order,
    only DTOs whose macros already lead their field list (or whose field order
    is not observable on the wire) may inherit this base.
    """

    calories: int = Field(ge=0)
    protein_g: float = Field(ge=0)
    carbs_g: float = Field(ge=0)
    fat_g: float = Field(ge=0)


class MacroTotals(BaseModel):
    """Aggregated macro totals (calories + protein/carbs/fat in grams).

    Used as a response-body fragment wherever the API returns "how much
    has been consumed / remains / is targeted" — e.g. daily summaries
    and entry-creation responses.
    """

    calories: int
    protein_g: float
    carbs_g: float
    fat_g: float


class MacroTargets(BaseModel):
    """User-configured daily macro targets plus an optional target weight.

    Request/response body for the targets endpoints. ``target_weight_lb``
    is stored as ``numeric(6,2)`` in the database (max ``9999.99``) and
    must round to at least ``0.01`` when provided.
    """

    calories: int = Field(gt=0)
    protein_g: float = Field(ge=0)
    carbs_g: float = Field(ge=0)
    fat_g: float = Field(ge=0)
    target_weight_lb: float | None = Field(default=None, gt=0, le=9999.99)

    @field_validator("target_weight_lb")
    @classmethod
    def _check_storable(cls, v: float | None) -> float | None:
        """Round ``target_weight_lb`` to two decimals and reject sub-storable values.

        **Inputs:**
        - v (float | None): Candidate target weight in pounds, or ``None``.

        **Outputs:**
        - float | None: The value re-quantized to two decimal places, or
          ``None`` when the caller did not supply a target.

        **Exceptions:**
        - ValueError: Raised when the value rounds to ``<= 0`` and therefore
          cannot be stored in the ``numeric(6,2)`` column.
        """
        if v is None:
            return v
        rounded = Decimal(str(v)).quantize(Decimal("0.01"), rounding=ROUND_HALF_EVEN)
        if rounded <= 0:
            raise ValueError("target_weight_lb must be at least 0.01")
        return float(rounded)
