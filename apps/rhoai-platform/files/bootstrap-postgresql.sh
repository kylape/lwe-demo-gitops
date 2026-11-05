#!/usr/bin/env bash
set -Eeuo pipefail

read_secret() {
  local key="$1" value
  value=$(oc get secret keycloak-db-secret -n postgresql \
    -o "jsonpath={.data.${key}}" 2>/dev/null || true)
  [[ -n "$value" ]] && printf '%s' "$value" | base64 -d || true
}

ensure_value() {
  local key="$1" length="$2" value
  value=$(read_secret "$key")
  if [[ -z "$value" ]]; then
    value=$(openssl rand -hex "$length")
  fi
  printf '%s' "$value"
}

PG_USER=$(ensure_value username 8)
PG_PASSWORD=$(ensure_value password 32)
PG_ADMIN_PASSWORD=$(ensure_value admin-password 32)

oc create secret generic keycloak-db-secret -n postgresql \
  --from-literal="username=${PG_USER}" \
  --from-literal="password=${PG_PASSWORD}" \
  --from-literal=database=keycloak \
  --from-literal="admin-password=${PG_ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | oc apply -f -
