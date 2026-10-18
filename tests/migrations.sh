#!/usr/bin/env bash
# Migration test against a throwaway Postgres (podman or docker):
#   1. fresh install of the image's version, migrator rerun is a no-op
#   2. upstream's schema of an older version (FROM_REF), adopted at
#      FROM_VERSION and upgraded by the migrator
#   3. both databases must have the same schema and the same settings keys
#
#   tests/migrations.sh <image> [FROM_REF] [FROM_VERSION]
# FROM_REF is an upstream commit (default: 71a64b4, version 3.3.1).
set -euo pipefail

IMG=${1:?image}
FROM_REF=${2:-71a64b4}
FROM_VERSION=${3:-3.3.1}
CT=${CONTAINER_TOOL:-$(command -v podman || command -v docker)}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAME=tm-migrations-test-$$
WORK=$(mktemp -d)
cleanup() { "$CT" rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

"$CT" run -d --name "$NAME" -e POSTGRES_USER=tm -e POSTGRES_PASSWORD=tmpw -e POSTGRES_DB=fresh \
    docker.io/library/postgres:18-alpine >/dev/null
for _ in $(seq 1 60); do "$CT" exec "$NAME" pg_isready -q -U tm -h 127.0.0.1 && break; sleep 1; done
sleep 2
psql() { "$CT" exec -i "$NAME" psql -v ON_ERROR_STOP=1 -q -U tm "$@"; }
psql -d fresh -c "CREATE DATABASE old OWNER tm"

migrate() {
    "$CT" run --rm --network "container:$NAME" --read-only --tmpfs /tmp \
        --cap-drop=ALL --security-opt no-new-privileges \
        -e TM_ENCRYPTION_KEY="$(openssl rand -hex 32)" -e TM_DB_HOST=127.0.0.1 \
        -e TM_DB_USER=tm -e TM_DB_PASSWORD=tmpw "$@" "$IMG" php /app/migrate.php
}

echo "== fresh install"
migrate -e TM_DB_NAME=fresh
echo "== rerun (no-op)"
migrate -e TM_DB_NAME=fresh | tee "$WORK/rerun"
grep -q 'up to date' "$WORK/rerun"

echo "== upgrade from upstream $FROM_REF ($FROM_VERSION)"
git -C "$ROOT/upstream" show "$FROM_REF:db_schema/postgresql.sql" | psql -d old >/dev/null
migrate -e TM_DB_NAME=old -e TM_DB_BASELINE_VERSION="$FROM_VERSION"

for db in fresh old; do
    "$CT" exec "$NAME" pg_dump -U tm -d "$db" --schema-only --no-owner \
        | grep -v -E '^--|^$|^SET |^SELECT pg_catalog|^\\(un)?restrict' > "$WORK/schema-$db.sql"
    psql -d "$db" -tA -c "SELECT key FROM settings ORDER BY key" > "$WORK/settings-$db.txt"
done
diff -u "$WORK/schema-fresh.sql" "$WORK/schema-old.sql"
diff -u "$WORK/settings-fresh.txt" "$WORK/settings-old.txt"
psql -d old -tA -c "SELECT nextval('auto_id_settings')" >/dev/null   # no collision left
echo "OK: upgraded $FROM_VERSION matches a fresh install"
