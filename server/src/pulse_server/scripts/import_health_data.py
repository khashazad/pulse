"""Import Apple Health + Hevy exports into Postgres.

Usage:
    uv run python -m pulse_server.scripts.import_health_data \\
        --apple /path/to/export.xml --hevy "/path/to/workout.csv" [--user-key khash]
"""

from __future__ import annotations

import argparse
import asyncio
from zoneinfo import ZoneInfo

from pulse_server import db
from pulse_server.activity import repository
from pulse_server.activity.apple_parser import parse_apple_export
from pulse_server.activity.hevy_parser import parse_hevy_csv
from pulse_server.config import get_settings


async def run_import(
    apple_path: str | None, hevy_path: str | None, user_key: str
) -> dict[str, tuple[int, int]]:
    """Parse the given export files and upsert them, returning per-source counts.

    **Inputs:**
    - apple_path (str | None): Path to Apple ``export.xml``, or None to skip.
    - hevy_path (str | None): Path to the Hevy CSV, or None to skip.
    - user_key (str): Owning user key applied to every row.

    **Outputs:**
    - dict[str, tuple[int, int]]: Keys ``apple_workouts``, ``daily_activity``,
      ``strength`` → ``(inserted, updated)``. Skipped sources report ``(0, 0)``.

    **Raises/Throws:**
    - sqlalchemy.exc.SQLAlchemyError: On DB connectivity or statement failure.
    """
    settings = get_settings()
    tz = ZoneInfo(settings.timezone)

    summary: dict[str, tuple[int, int]] = {
        "apple_workouts": (0, 0),
        "daily_activity": (0, 0),
        "strength": (0, 0),
        "linked": (0, 0),
    }

    await db.init_pool(settings.database_url)
    try:
        async with db.get_session() as session, db.transaction(session):
            if apple_path:
                workouts, days = parse_apple_export(apple_path, user_key=user_key)
                summary["apple_workouts"] = await repository.upsert_apple_workouts(
                    session, workouts
                )
                summary["daily_activity"] = await repository.upsert_daily_activity(session, days)
            if hevy_path:
                s_workouts, s_sets = parse_hevy_csv(hevy_path, user_key=user_key, tz=tz)
                summary["strength"] = await repository.upsert_strength(session, s_workouts, s_sets)
            summary["linked"] = (await repository.link_apple_to_strength(session, user_key), 0)
    finally:
        await db.close_pool()

    return summary


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint: parse args, run the import, print a per-table summary.

    **Inputs:**
    - argv (list[str] | None): Argument vector for testing; defaults to sys.argv.

    **Outputs:**
    - int: Process exit code (0 on success).
    """
    parser = argparse.ArgumentParser(
        description="Import Apple Health + Hevy exports into Postgres."
    )
    parser.add_argument(
        "--apple", dest="apple", default=None, help="Path to Apple Health export.xml"
    )
    parser.add_argument("--hevy", dest="hevy", default=None, help="Path to the Hevy CSV export")
    parser.add_argument(
        "--user-key",
        dest="user_key",
        default=None,
        help="Owning user key (defaults to settings.legacy_user_key)",
    )
    args = parser.parse_args(argv)

    if not args.apple and not args.hevy:
        parser.error("provide at least one of --apple or --hevy")

    user_key = args.user_key or get_settings().legacy_user_key
    summary = asyncio.run(run_import(args.apple, args.hevy, user_key))

    for name, (inserted, updated) in summary.items():
        print(f"{name:16} inserted={inserted:>6} updated={updated:>6}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
