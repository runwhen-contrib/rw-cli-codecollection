#!/usr/bin/env bash
set -euo pipefail
set -x
# REQUIRED: CONTEXT, NAMESPACE, POSTGRESCLUSTER_NAME
# Extracts max_client_conn, default_pool_size, max_db_connections from nested pgBouncer config via jq walk.
# Output: connection_limits_issues.json

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${POSTGRESCLUSTER_NAME:?Must set POSTGRESCLUSTER_NAME}"

KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
CRD="postgresclusters.postgres-operator.crunchydata.com"
OUTPUT_FILE="connection_limits_issues.json"
issues_json='[]'

# First value for key anywhere under config (PGO nests keys by version)
first_key() {
  local json="$1"
  local key="$2"
  echo "$json" | jq -r --arg k "$key" '.. | objects | select(has($k)) | .[$k] | tostring' | head -1
}

to_int() {
  local v="$1"
  [[ -z "$v" ]] && echo "" && return
  # strip non-digits for safety
  echo "$v" | tr -cd '0-9'
}

list_clusters() {
  if [[ "${POSTGRESCLUSTER_NAME,,}" == "all" ]]; then
    "${KUBECTL}" get "$CRD" -n "$NAMESPACE" --context "$CONTEXT" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
  else
    echo "$POSTGRESCLUSTER_NAME"
  fi
}

check_one() {
  local name="$1"
  local cr_json pgb_cfg mcc dps mdb
  if ! cr_json=$("${KUBECTL}" get "$CRD" "$name" -n "$NAMESPACE" --context "$CONTEXT" -o json 2>/dev/null); then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Cannot read PostgresCluster \`$name\` for connection limit check" \
      --arg details "kubectl get failed" \
      --argjson severity 3 \
      --arg next_steps "Verify cluster name, namespace, and RBAC." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
    return
  fi

  pgb_cfg=$(echo "$cr_json" | jq -c '.spec.proxy.pgBouncer // empty')
  if [[ -z "$pgb_cfg" || "$pgb_cfg" == "null" ]]; then
    echo "PostgresCluster $name: no spec.proxy.pgBouncer; skipping limit checks."
    return
  fi

  local cfg_json
  cfg_json=$(echo "$cr_json" | jq -c '.spec.proxy.pgBouncer.config // {}')
  mcc=$(first_key "$cfg_json" "max_client_conn")
  dps=$(first_key "$cfg_json" "default_pool_size")
  mdb=$(first_key "$cfg_json" "max_db_connections")

  local mcc_i dps_i mdb_i
  mcc_i=$(to_int "$mcc")
  dps_i=$(to_int "$dps")
  mdb_i=$(to_int "$mdb")

  echo "PostgresCluster $name: max_client_conn=${mcc:-unset} default_pool_size=${dps:-unset} max_db_connections=${mdb:-unset}"

  if [[ -n "$dps_i" && -n "$mdb_i" && "$dps_i" -gt "$mdb_i" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "PgBouncer pool sizing risk on \`$name\`" \
      --arg details "default_pool_size ($dps_i) exceeds max_db_connections ($mdb_i); backends may be oversubscribed." \
      --argjson severity 3 \
      --arg next_steps "Raise max_db_connections (PostgreSQL-side) or lower default_pool_size so pool demand fits server limits." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  fi

  if [[ -n "$mcc_i" && -n "$dps_i" && "$mcc_i" -lt "$dps_i" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "max_client_conn lower than default_pool_size on \`$name\`" \
      --arg details "max_client_conn=$mcc_i is below default_pool_size=$dps_i (unusual; verify pgbouncer.ini semantics)." \
      --argjson severity 2 \
      --arg next_steps "Review PgBouncer configuration; max_client_conn should generally be large enough for expected client concurrency." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  fi
}

while IFS= read -r c; do
  [[ -z "$c" ]] && continue
  check_one "$c"
done < <(list_clusters)

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
exit 0
