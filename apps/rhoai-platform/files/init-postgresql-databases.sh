#!/usr/bin/env bash
set -Eeuo pipefail

export PGPASSWORD="${POSTGRESQL_ADMIN_PASSWORD}"

for attempt in $(seq 1 60); do
  if pg_isready -h psql-keycloak.postgresql.svc.cluster.local -p 5432 -U postgres >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" -eq 60 ]]; then
    echo "timed out waiting for PostgreSQL" >&2
    exit 1
  fi
  sleep 5
done

for database in keycloak batch; do
  exists=$(psql -h psql-keycloak.postgresql.svc.cluster.local -U postgres \
    -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '${database}'")
  if [[ "$exists" != "1" ]]; then
    psql -h psql-keycloak.postgresql.svc.cluster.local -U postgres \
      -d postgres -v ON_ERROR_STOP=1 \
      -c "CREATE DATABASE \"${database}\" OWNER \"${POSTGRESQL_USER}\""
  fi
done
