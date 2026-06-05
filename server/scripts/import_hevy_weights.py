"""One-shot import of Hevy measurement_data.csv into weight_entries.

Usage:
    uv run python scripts/import_hevy_weights.py <csv-path> [--dry-run] [--user-key khash]

CSV header: date,weight_lbs,fat_percent,neck_cm,... (only `date` + `weight_lbs` are read).
Dates look like `15 Sep 2025, 00:00`. Empty weight rows are skipped.
Idempotent: ON CONFLICT (user_key, log_date) DO UPDATE — re-runs overwrite.
"""

from __future__ import annotations

import argparse
import asyncio
import csv
from datetime import date as DateValue
from datetime import datetime as DateTimeValue
from decimal import Decimal
from pathlib import Path
from zoneinfo import ZoneInfo

from pulse_server.config import get_settings
from pulse_server.db import close_pool, get_session, init_pool, transaction
from pulse_server.services.weight_service import upsert_weight


def _parse_date(raw: str) -> DateValue:
    return DateTimeValue.strptime(raw.strip(), "%d %b %Y, %H:%M").date()


def _parse_rows(csv_path: Path) -> list[tuple[DateValue, Decimal]]:
    rows: list[tuple[DateValue, Decimal]] = []
    with csv_path.open(newline="") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            raw_weight = (row.get("weight_lbs") or "").strip()
            if not raw_weight:
                continue
            log_date = _parse_date(row["date"])
            weight = Decimal(raw_weight)
            rows.append((log_date, weight))
    rows.sort(key=lambda r: r[0])
    return rows


async def _run(csv_path: Path, user_key: str, dry_run: bool) -> None:
    rows = _parse_rows(csv_path)
    if not rows:
        print("parsed 0 rows")
        return
    print(f"parsed {len(rows)} rows ({rows[0][0]} -> {rows[-1][0]})")
    if dry_run:
        for d, w in rows[:5]:
            print(f"  {d} {w} lb")
        print("  ...")
        return

    settings = get_settings()
    await init_pool(settings.database_url)
    tz = ZoneInfo(settings.timezone)
    now = DateTimeValue.now(tz=tz)

    try:
        async with get_session() as session, transaction(session):
            for log_date, weight in rows:
                await upsert_weight(
                    session=session,
                    user_key=user_key,
                    log_date=log_date,
                    weight=weight,
                    unit="lb",
                    now=now,
                )
        print(f"upserted {len(rows)} weight entries for user_key={user_key}")
    finally:
        await close_pool()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv_path", type=Path)
    parser.add_argument("--user-key", default=None, help="defaults to settings.legacy_user_key")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    user_key = args.user_key or get_settings().legacy_user_key
    asyncio.run(_run(args.csv_path, user_key, args.dry_run))


if __name__ == "__main__":
    main()
