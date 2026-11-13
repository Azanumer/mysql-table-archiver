#!/usr/bin/env bash
# archive-table.sh — move old rows into an archive table, in batches.
#
#   ./archive-table.sh --database app --table wp_posts --date-column post_date --days 365
#
# Rows older than --days (by --date-column) are INSERT ... SELECTed into
# archive_<table> (created with LIKE <table> when missing) and then deleted
# from the source, in --batch-size chunks so long tables never lock up.
# Nothing is lost: rows only leave the source after the matching archive
# INSERT succeeded, and the archive table keeps the exact same schema.
#
# Safety: a real run needs --yes. Without --yes (or with --dry-run) the
# script only reports how many rows would move.
#
# Credentials: uses ~/.my.cnf (or MYSQL_PWD / --defaults-file) — no password
# on the command line. Exit codes: 0 ok, 1 usage/mysql error, 2 nothing to do.
set -euo pipefail

PROG="$(basename "$0")"
DATABASE=""
TABLE=""
DATE_COLUMN="created_at"
DAYS=""
BATCH_SIZE=1000
ARCHIVE_TABLE=""
DRY_RUN=0
CONFIRM=0
JSON=0
QUIET=0
LOGFILE=""
MYSQL_ARGS=()

usage() {
    cat <<EOF
Usage: $PROG --database DB --table TABLE --days N [options]

Required:
  --database DB        Database name
  --table TABLE        Source table (letters, digits, _ only)
  --days N             Archive rows older than N days

Options:
  --date-column COL    Date/datetime column to compare (default: created_at)
  --batch-size N       Rows per batch (default: 1000)
  --archive-table T    Archive table name (default: archive_<table>)
  --dry-run            Only report how many rows would move
  --yes                Confirm the real run (required without --dry-run)
  --defaults-file F    Extra mysql defaults file (repeatable)
  --json               Machine-readable output
  --quiet              Print only errors / the final summary line
  --logfile FILE       Append a one-line summary to FILE
  -h, --help           Show this help
EOF
    exit "${1:-0}"
}

log() { if [ "$QUIET" -eq 0 ]; then echo "$*"; fi; }
err() { echo "$PROG: $*" >&2; }

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n")))' <<<"$1"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --database)      DATABASE="$2"; shift 2 ;;
        --table)         TABLE="$2"; shift 2 ;;
        --date-column)   DATE_COLUMN="$2"; shift 2 ;;
        --days)          DAYS="$2"; shift 2 ;;
        --batch-size)    BATCH_SIZE="$2"; shift 2 ;;
        --archive-table) ARCHIVE_TABLE="$2"; shift 2 ;;
        --dry-run)       DRY_RUN=1; shift ;;
        --yes)           CONFIRM=1; shift ;;
        --defaults-file) MYSQL_ARGS+=( "--defaults-file=$2" ); shift 2 ;;
        --json)          JSON=1; shift ;;
        --quiet)         QUIET=1; shift ;;
        --logfile)       LOGFILE="$2"; shift 2 ;;
        -h|--help)       usage 0 ;;
        *) err "unknown option: $1"; usage 1 ;;
    esac
done

[ -n "$DATABASE" ] || { err "--database is required"; usage 1; }
[ -n "$TABLE" ]    || { err "--table is required"; usage 1; }
[ -n "$DAYS" ]     || { err "--days is required"; usage 1; }
[[ "$DAYS" =~ ^[0-9]+$ ]]        || { err "--days must be a whole number"; exit 1; }
[[ "$BATCH_SIZE" =~ ^[0-9]+$ ]]  || { err "--batch-size must be a whole number"; exit 1; }
[ "$BATCH_SIZE" -gt 0 ]          || { err "--batch-size must be > 0"; exit 1; }

# Identifiers are interpolated into SQL, so allow only safe characters.
valid_ident() { [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]; }
valid_ident "$DATABASE"    || { err "invalid database name: $DATABASE"; exit 1; }
valid_ident "$TABLE"       || { err "invalid table name: $TABLE"; exit 1; }
valid_ident "$DATE_COLUMN" || { err "invalid date column: $DATE_COLUMN"; exit 1; }
ARCHIVE_TABLE="${ARCHIVE_TABLE:-archive_${TABLE}}"
valid_ident "$ARCHIVE_TABLE" || { err "invalid archive table name: $ARCHIVE_TABLE"; exit 1; }

if [ "$DRY_RUN" -eq 0 ] && [ "$CONFIRM" -eq 0 ]; then
    err "refusing to move rows without --yes (or use --dry-run to preview)"
    exit 1
fi

mysqlq() { mysql "${MYSQL_ARGS[@]}" -N -B -e "$1" "$DATABASE"; }

# Pre-flight: database reachable, source table + date column exist.
if ! mysqlq "SELECT 1;" >/dev/null 2>&1; then
    err "cannot connect to MySQL (check ~/.my.cnf or --defaults-file)"
    exit 1
fi
SRC_EXISTS=$(mysqlq "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DATABASE}' AND table_name='${TABLE}';")
[ "$SRC_EXISTS" = "1" ] || { err "table ${DATABASE}.${TABLE} does not exist"; exit 1; }
COL_EXISTS=$(mysqlq "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='${DATABASE}' AND table_name='${TABLE}' AND column_name='${DATE_COLUMN}';")
[ "$COL_EXISTS" = "1" ] || { err "column ${DATE_COLUMN} does not exist on ${TABLE}"; exit 1; }

CUTOFF_CONDITION="\`${DATE_COLUMN}\` < DATE_SUB(NOW(), INTERVAL ${DAYS} DAY)"

TOTAL=$(mysqlq "SELECT COUNT(*) FROM \`${TABLE}\` WHERE ${CUTOFF_CONDITION};")
if [ "$TOTAL" = "0" ]; then
    log "nothing to archive: no rows older than ${DAYS} days in ${TABLE}"
    [ "$JSON" -eq 1 ] && printf '{"database":%s,"table":%s,"archive_table":%s,"days":%s,"moved":0,"status":"nothing_to_do"}\n' "$(json_escape "$DATABASE")" "$(json_escape "$TABLE")" "$(json_escape "$ARCHIVE_TABLE")" "$DAYS"
    exit 2
fi

if [ "$DRY_RUN" -eq 1 ]; then
    log "dry-run: ${TOTAL} row(s) older than ${DAYS} days would move from ${TABLE} to ${ARCHIVE_TABLE}"
    [ "$JSON" -eq 1 ] && printf '{"database":%s,"table":%s,"archive_table":%s,"days":%s,"would_move":%s,"status":"dry_run"}\n' "$(json_escape "$DATABASE")" "$(json_escape "$TABLE")" "$(json_escape "$ARCHIVE_TABLE")" "$DAYS" "$TOTAL"
    exit 0
fi

# Create the archive table with the source schema when missing.
mysqlq "CREATE TABLE IF NOT EXISTS \`${ARCHIVE_TABLE}\` LIKE \`${TABLE}\`;" >/dev/null

MOVED=0
while true; do
    # One batch: copy, then delete exactly the rows just copied (same WHERE
    # plus the batch limit keeps the two statements aligned). Run inside one
    # mysql call so a failure aborts before the DELETE.
    BATCH=$(mysqlq "
        START TRANSACTION;
        INSERT INTO \`${ARCHIVE_TABLE}\`
            SELECT * FROM \`${TABLE}\`
            WHERE ${CUTOFF_CONDITION}
            ORDER BY \`${DATE_COLUMN}\` ASC
            LIMIT ${BATCH_SIZE};
        SELECT ROW_COUNT();
        DELETE FROM \`${TABLE}\`
            WHERE ${CUTOFF_CONDITION}
            ORDER BY \`${DATE_COLUMN}\` ASC
            LIMIT ${BATCH_SIZE};
        COMMIT;
    " | head -n 1)
    # ROW_COUNT() after the INSERT is the first result row.
    BATCH="${BATCH:-0}"
    MOVED=$((MOVED + BATCH))
    log "archived batch of ${BATCH} row(s) (${MOVED}/${TOTAL} so far)"
    [ "$BATCH" -eq 0 ] && break
    [ "$MOVED" -ge "$TOTAL" ] && break
done

log "done: moved ${MOVED} row(s) from ${TABLE} to ${ARCHIVE_TABLE} (older than ${DAYS} days)"
[ "$JSON" -eq 1 ] && printf '{"database":%s,"table":%s,"archive_table":%s,"days":%s,"moved":%s,"status":"ok"}\n' "$(json_escape "$DATABASE")" "$(json_escape "$TABLE")" "$(json_escape "$ARCHIVE_TABLE")" "$DAYS" "$MOVED"
[ -n "$LOGFILE" ] && printf '%s %s: moved %s row(s) %s -> %s (older than %s days)\n' "$(date '+%F %T')" "$DATABASE" "$MOVED" "$TABLE" "$ARCHIVE_TABLE" "$DAYS" >> "$LOGFILE"
exit 0
