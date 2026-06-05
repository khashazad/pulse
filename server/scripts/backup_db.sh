#!/usr/bin/env bash
#
# Backup the Pulse Supabase database to timestamped local SQL dumps.
#
# Produces the three-file backup format from Supabase's backup/restore docs
# (https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore):
#   roles.sql  — cluster roles
#   schema.sql — full schema
#   data.sql   — data only, COPY statements
#
# Usage:
#   DATABASE_URL='postgresql://postgres.<ref>:<password>@...' ./backup_db.sh
#
# Inputs (environment):
#   DATABASE_URL — required; Supabase connection string (session pooler or
#                  direct), percent-encoded as required by `supabase db dump`.
#   BACKUP_ROOT  — optional; base directory for backups
#                  (default: $HOME/Backups/pulse).
#
# Output: dumps are written to $BACKUP_ROOT/<YYYY-MM-DD_HHMMSS>.incomplete/
# and the directory is renamed to $BACKUP_ROOT/<YYYY-MM-DD_HHMMSS>/ only after
# all three files pass validation — a directory without the ".incomplete"
# suffix is a verified backup; one with it is a failed/aborted run.
#
# Exits non-zero if DATABASE_URL is unset, the supabase CLI or Docker daemon
# is unavailable, a dump command fails, any resulting file is missing/empty,
# or data.sql contains no COPY statements.

set -euo pipefail

# Print an error message to stderr and exit with status 1.
#
# Parameters:
#   $1 (string) — the error message to print.
#
# Returns: nothing; terminates the script with exit status 1.
die() {
  echo "error: $1" >&2
  exit 1
}

# Verify that a dump file exists and is non-empty, then print its size.
#
# Parameters:
#   $1 (string) — path to the dump file to check.
#
# Returns: nothing; prints "<size>\t<path>" (du -h output) to stdout.
# Exits with status 1 (via die) if the file is missing or empty.
check_dump() {
  local file="$1"
  [[ -s "$file" ]] || die "dump file missing or empty: $file"
  du -h "$file"
}

[[ -n "${DATABASE_URL:-}" ]] || die "DATABASE_URL is not set. Get the connection string from the Supabase dashboard (Connect), percent-encode any special characters in the password, and run: DATABASE_URL='...' $0"

command -v supabase >/dev/null || die "supabase CLI not found"
docker info >/dev/null 2>&1 || die "Docker daemon not running (required by 'supabase db dump')"

BACKUP_ROOT="${BACKUP_ROOT:-$HOME/Backups/pulse}"
DEST="$BACKUP_ROOT/$(date +%Y-%m-%d_%H%M%S)"
WORK="$DEST.incomplete"

[[ -e "$DEST" ]] && die "backup directory already exists: $DEST"
mkdir -p "$BACKUP_ROOT"
mkdir "$WORK"

echo "Backing up to $WORK"

echo "--> roles.sql"
supabase db dump --db-url "$DATABASE_URL" -f "$WORK/roles.sql" --role-only

echo "--> schema.sql"
supabase db dump --db-url "$DATABASE_URL" -f "$WORK/schema.sql"

echo "--> data.sql"
supabase db dump --db-url "$DATABASE_URL" -f "$WORK/data.sql" --use-copy --data-only \
  -x "storage.buckets_vectors" -x "storage.vector_indexes"

echo
check_dump "$WORK/roles.sql"
check_dump "$WORK/schema.sql"
check_dump "$WORK/data.sql"
grep -q '^COPY ' "$WORK/data.sql" || die "data.sql contains no COPY statements — dump has no data"

[[ -e "$DEST" ]] && die "backup directory appeared during run, leaving $WORK in place: $DEST"
mv "$WORK" "$DEST"

echo
echo "Backup complete: $DEST"
