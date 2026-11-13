# MySQL Table Archiver

Move old rows out of a busy table into an `archive_<table>` table — same schema, batched, and safe to run from cron. Keeps hot tables small without losing history.

## Features

- **Batched moves** — `--batch-size` (default 1000) so a million-row table never locks up the server.
- **Same-schema archive** — creates `archive_<table>` with `CREATE TABLE ... LIKE` when missing.
- **Lossless by design** — rows are deleted from the source only after the matching archive INSERT succeeded, in one transaction per batch.
- **Safe by default** — a real run needs `--yes`; without it (or with `--dry-run`) the script only reports how many rows would move.
- **Cron-friendly** — `--json` output, `--logfile` summary lines, exit codes 0 ok / 1 error / 2 nothing to do.
- **Identifier validation** — database/table/column names must be `[A-Za-z0-9_]` (they are interpolated into SQL, never user-supplied free text).

## Usage

```bash
# Preview: how many wp_posts rows are older than 365 days?
./archive-table.sh --database myblog --table wp_posts \
    --date-column post_date --days 365 --dry-run

# Actually move them (archives to archive_wp_posts):
./archive-table.sh --database myblog --table wp_posts \
    --date-column post_date --days 365 --yes --logfile /var/log/archive.log

# Machine-readable output for monitoring:
./archive-table.sh --database myblog --table wp_comments \
    --date-column comment_date --days 180 --yes --json
```

Credentials come from `~/.my.cnf` (or `--defaults-file`) — never put a password on the command line.

## Cron example

Archive yesterday's-old logs every Sunday at 03:00:

```cron
0 3 * * 0 /opt/scripts/archive-table.sh --database myblog --table wp_logs --date-column created_at --days 90 --yes --quiet --logfile /var/log/archive.log
```

## License

MIT — see [LICENSE](LICENSE).
