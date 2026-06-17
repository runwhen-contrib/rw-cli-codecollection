#!/usr/bin/env bash
# Shared helpers for PostgresCluster PgBouncer spec validation (sourced by task scripts).

KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
PG_CRD="postgresclusters.postgres-operator.crunchydata.com"

list_postgrescluster_names() {
  local mode
  mode="$(echo "${POSTGRESCLUSTER_NAME:-}" | tr '[:upper:]' '[:lower:]')"
  if [ "$mode" = "all" ]; then
    ${KUBECTL} get "$PG_CRD" -n "${NAMESPACE:?}" --context "${CONTEXT:?}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
  else
    echo "${POSTGRESCLUSTER_NAME:?}"
  fi
}

fetch_cluster_json() {
  local name="$1"
  ${KUBECTL} get "$PG_CRD" "$name" -n "${NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null
}

global_setting() {
  # Args: cluster_json key (e.g. pool_mode)
  local json="$1"
  local key="$2"
  echo "$json" | jq -r --arg k "$key" '
    .spec.proxy.pgBouncer.config.global // {} |
    if has($k) then .[$k] else empty end
  ' 2>/dev/null | head -1
}

global_setting_alt() {
  # Some clusters use camelCase in YAML that serializes differently; try common aliases.
  local json="$1"
  local key="$2"
  local v
  v="$(global_setting "$json" "$key")"
  if [ -n "$v" ] && [ "$v" != "null" ]; then
    echo "$v"
    return
  fi
  case "$key" in
    pool_mode) global_setting "$json" "poolMode" ;;
    default_pool_size) global_setting "$json" "defaultPoolSize" ;;
    max_client_conn) global_setting "$json" "maxClientConn" ;;
    max_db_connections) global_setting "$json" "maxDbConnections" ;;
    *) echo "" ;;
  esac
}

numeric_or_empty() {
  local s="$1"
  if [ -z "$s" ] || [ "$s" = "null" ]; then
    echo ""
    return
  fi
  if [[ "$s" =~ ^[0-9]+$ ]]; then
    echo "$s"
  else
    echo ""
  fi
}
