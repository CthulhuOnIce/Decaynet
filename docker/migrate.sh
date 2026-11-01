#!/bin/sh
# Decaynet migration runner. SPDX-License-Identifier: AGPL-3.0-or-later
#
#   DATABASE_URL  postgres://postgres:PASSWORD@HOST:5432/postgres   (required)
#   SEED=1        also load seed.sql (only on an empty database)
#
# The target must be a Supabase database (it needs the auth and storage schemas).
set -eu

: "${DATABASE_URL:?Set DATABASE_URL to your Supabase Postgres connection string}"
PSQL="psql $DATABASE_URL -v ON_ERROR_STOP=1 -q -X"

echo "→ Waiting for the database…"
i=0
until $PSQL -c 'select 1' >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -gt 30 ] && { echo "✗ Database not reachable"; exit 1; }
  sleep 2
done

$PSQL <<'SQL'
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (
  version text primary key,
  statements text[],
  name text
);
SQL

applied=0
for f in /migrations/migrations/*.sql; do
  base=$(basename "$f" .sql)
  version=${base%%_*}
  name=${base#*_}
  exists=$($PSQL -At -c "select 1 from supabase_migrations.schema_migrations where version = '$version'")
  if [ "$exists" = "1" ]; then
    echo "  ✓ $base (already applied)"
    continue
  fi
  echo "  → applying $base"
  $PSQL --single-transaction -o /dev/null -f "$f" \
    -c "insert into supabase_migrations.schema_migrations (version, name) values ('$version', '$name')"
  applied=$((applied + 1))
done
echo "→ $applied migration(s) applied."

if [ "${SEED:-0}" = "1" ]; then
  count=$($PSQL -At -c "select count(*) from public.entities")
  if [ "$count" = "0" ]; then
    echo "→ Loading seed data"
    $PSQL --single-transaction -f /migrations/seed.sql >/dev/null
  else
    echo "→ Seed skipped: database already has $count entities."
  fi
fi
echo "✓ Done."
