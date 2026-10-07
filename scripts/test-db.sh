#!/usr/bin/env bash
# Applies supabase/migrations to a throwaway Postgres and runs supabase/tests.
#
#   scripts/test-db.sh                  # starts a temporary local cluster (needs initdb/pg_ctl)
#   DATABASE_URL=postgres://... scripts/test-db.sh   # uses an existing, EMPTY database
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cleanup() { :; }
trap 'cleanup' EXIT

if [[ -z "${DATABASE_URL:-}" ]]; then
  pgbin="$(dirname "$(command -v initdb 2>/dev/null || ls /usr/lib/postgresql/*/bin/initdb | tail -1)")"
  tmp="$(mktemp -d)"
  "$pgbin/initdb" -D "$tmp/data" -U postgres -A trust >/dev/null
  "$pgbin/pg_ctl" -D "$tmp/data" -o "-k $tmp -c listen_addresses=''" -l "$tmp/log" -w start >/dev/null
  cleanup() { "$pgbin/pg_ctl" -D "$tmp/data" -m immediate stop >/dev/null; rm -rf "$tmp"; }
  DATABASE_URL="postgresql://postgres@/postgres?host=$tmp"
fi

run() { psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -o /dev/null -f "$1"; }

run "$root/supabase/tests/00_supabase_stubs.sql"
for f in "$root"/supabase/migrations/*.sql; do echo "migrate  $(basename "$f")"; run "$f"; done
for f in "$root"/supabase/tests/[1-9]*.sql; do echo "test     $(basename "$f")"; run "$f"; done
echo "All database tests passed."
