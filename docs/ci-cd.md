# Backups

This repo has no CI pipeline. Pulse is a single-user app; automated lint/test/
security gating was removed to cut GitHub Actions and Backblaze B2 overhead.
Run tests locally before pushing (see each subproject's `CLAUDE.md` section for
commands).

The only workflow left is `.github/workflows/backup.yml`, an off-site backup
that runs every 3 days (and on manual dispatch): a custom-format `pg_dump` of
the Supabase database (verified with `pg_restore --list`, 30-day retention)
and an `rclone copy` of the B2 photo bucket into date/tag folders (never
deletes from the backup), both into Google Drive.

**Why it is cheap.** Backblaze's free tier caps daily transactions, and this
job used to blow through it: it ran `rclone copy` + `rclone check` against B2
for *every* photo on *every* run, so the transaction count grew with the whole
library rather than with new photos. It now lists the Drive mirror once (Google
quota, free) and skips any photo whose three variants — `archive`, `display`,
`thumb` — are already there, so a steady-state run makes **zero** per-photo B2
calls. The only unconditional B2 cost is one recursive bucket listing for the
orphan tripwire. Cadence dropped from nightly to every 3 days on top of that.

Completeness is judged by destination listing rather than a stored manifest, so
the job is self-healing: delete something from the Drive mirror and the next run
puts it back. A partially-copied folder re-copies rather than being trusted.

Required secrets are documented in the workflow header
(`BACKUP_DATABASE_URL`, the four `S3_*` values, `GDRIVE_RCLONE_TOKEN`,
`GDRIVE_FOLDER_ID`). The local equivalents for manual runs remain
`server/scripts/backup_db.sh` and `server/scripts/backup_photos.sh`.

Restore drill (do this once, and after schema overhauls):

```bash
rclone copy gdrive:db/<latest>.dump . && pg_restore --list <latest>.dump
createdb pulse_restore && pg_restore -d pulse_restore --no-owner <latest>.dump
```

## Deployment

Railway auto-deploys `main` directly — pushing to `main` ships. There is no
CI gate in front of it.
