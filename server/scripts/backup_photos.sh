#!/usr/bin/env bash
#
# Back up the Pulse progress-photo bucket (Backblaze B2) to a local mirror.
#
# The object store is the ONLY copy of the photos (Postgres holds metadata
# only), so this script maintains a local second copy via `rclone copy`.
# `copy` is used instead of `sync` deliberately: it never deletes from the
# destination, so an accidental (or malicious) deletion in the bucket cannot
# propagate into the backup on the next run. Objects deleted from the bucket
# therefore accumulate locally — that is the point of a backup.
#
# Usage:
#   S3_ENDPOINT='https://s3.us-east-005.backblazeb2.com' \
#   S3_BUCKET='pulse-photos' \
#   S3_ACCESS_KEY_ID='...' S3_SECRET_ACCESS_KEY='...' ./backup_photos.sh
#
# The four S3_* values are the same ones the server uses (Railway service
# variables, or the B2 console).
#
# Inputs (environment):
#   S3_ENDPOINT           — required; S3-compatible endpoint URL.
#   S3_BUCKET             — required; bucket name.
#   S3_ACCESS_KEY_ID      — required; access key id.
#   S3_SECRET_ACCESS_KEY  — required; secret access key.
#   BACKUP_ROOT           — optional; base directory for the mirror
#                           (default: $HOME/Backups/pulse-photos).
#
# Output: an incrementally-updated mirror at $BACKUP_ROOT/<bucket>/ — only
# new/changed objects are downloaded on each run. After copying, the run is
# verified with `rclone check --one-way` (every bucket object must exist
# locally with a matching hash/size) and the bucket vs local object counts
# are printed.
#
# Exits non-zero if any required variable is unset, rclone is unavailable,
# the copy fails, or post-copy verification finds bucket objects missing
# from the mirror.
#
# SECURITY: credentials are passed to rclone via RCLONE_CONFIG_* environment
# variables (never argv), so they are not visible in `ps` output and no
# rclone config file is written.

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

# Require that an environment variable is set and non-empty.
#
# Parameters:
#   $1 (string) — the name of the required environment variable.
#
# Returns: nothing; exits with status 1 (via die) when the variable is
# unset or empty.
require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "$name is not set. Pull it from the Railway service variables (or the B2 console) and run: $name='...' $0"
}

require_env S3_ENDPOINT
require_env S3_BUCKET
require_env S3_ACCESS_KEY_ID
require_env S3_SECRET_ACCESS_KEY
command -v rclone >/dev/null || die "rclone not found (brew install rclone)"

# On-the-fly remote named PULSE, configured entirely through environment
# variables so no secret ever reaches a command line or config file.
export RCLONE_CONFIG_PULSE_TYPE=s3
export RCLONE_CONFIG_PULSE_PROVIDER=Other
export RCLONE_CONFIG_PULSE_ENDPOINT="$S3_ENDPOINT"
export RCLONE_CONFIG_PULSE_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
export RCLONE_CONFIG_PULSE_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"

BACKUP_ROOT="${BACKUP_ROOT:-$HOME/Backups/pulse-photos}"
DEST="$BACKUP_ROOT/$S3_BUCKET"
mkdir -p "$DEST"

echo "Backing up PULSE:$S3_BUCKET -> $DEST"
rclone copy "PULSE:$S3_BUCKET" "$DEST" --transfers 8 --stats-one-line --stats 15s

echo
echo "Verifying (every bucket object must exist locally with a matching hash)"
rclone check "PULSE:$S3_BUCKET" "$DEST" --one-way \
  || die "verification failed: bucket objects are missing from or differ in $DEST"

echo
echo "Bucket:  $(rclone size "PULSE:$S3_BUCKET")"
echo "Mirror:  $(rclone size "$DEST")"
echo "Backup complete: $DEST"
