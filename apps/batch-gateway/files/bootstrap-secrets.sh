#!/usr/bin/env bash
set -Eeuo pipefail

read_secret() {
  local namespace="$1" name="$2" key="$3"
  local value
  value=$(oc get secret "$name" -n "$namespace" \
    -o "jsonpath={.data.${key}}" 2>/dev/null || true)
  [[ -n "$value" ]] && printf '%s' "$value" | base64 -d || true
}

ensure_value() {
  local namespace="$1" name="$2" key="$3" length="$4"
  local value
  value=$(read_secret "$namespace" "$name" "$key")
  if [[ -z "$value" ]]; then
    value=$(openssl rand -hex "$length")
  fi
  printf '%s' "$value"
}

apply_secret() {
  local namespace="$1" name="$2"
  shift 2
  oc create secret generic "$name" -n "$namespace" "$@" \
    --dry-run=client -o yaml | oc apply -f -
}

PG_USER=$(read_secret postgresql keycloak-db-secret username)
PG_PASSWORD=$(read_secret postgresql keycloak-db-secret password)
if [[ -z "$PG_USER" || -z "$PG_PASSWORD" ]]; then
  echo "PostgreSQL credentials are missing; sync the rhoai-platform profile first" >&2
  exit 1
fi
REDIS_PASSWORD=$(ensure_value redis redis-secret password 32)
MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-batch-gateway}"
MINIO_SECRET_KEY=$(ensure_value minio minio-secret secretkey 32)

apply_secret redis redis-secret \
  --from-literal="password=${REDIS_PASSWORD}"
apply_secret minio minio-secret \
  --from-literal="accesskey=${MINIO_ACCESS_KEY}" \
  --from-literal="secretkey=${MINIO_SECRET_KEY}"

REDIS_URL="redis://:${REDIS_PASSWORD}@redis.redis.svc.cluster.local:6379/1"
POSTGRESQL_URL="postgresql://${PG_USER}:${PG_PASSWORD}@psql-keycloak.postgresql.svc.cluster.local:5432/batch?sslmode=disable"
apply_secret batch-api batch-gateway-secrets \
  --from-literal="redis-url=${REDIS_URL}" \
  --from-literal="postgresql-url=${POSTGRESQL_URL}" \
  --from-literal="s3-secret-access-key=${MINIO_SECRET_KEY}"
