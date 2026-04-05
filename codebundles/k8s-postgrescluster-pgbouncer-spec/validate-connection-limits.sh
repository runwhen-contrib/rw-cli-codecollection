#!/usr/bin/env bash
set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# REQUIRED: CONTEXT, NAMESPACE, POSTGRESCLUSTER_NAME
# Writes: connection_limits_issues.json
# Validates ordering of default_pool_size, max_client_conn, max_db_connections where present.
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${POSTGRESCLUSTER_NAME:?Must set POSTGRESCLUSTER_NAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-pgbouncer-spec.sh"

OUTPUT_FILE="connection_limits_issues.json"
issues_json='[]'

to_int() {
  local s="$1"
  s=$(echo "$s" | tr -d '[:space:]')
  [[ -z "$s" || "$s" == "null" ]] && echo "" && return
  [[ "$s" =~ ^[0-9]+$ ]] && echo "$s" && return
  echo ""
}

resolve_cluster_names() {
  if [[ "${POSTGRESCLUSTER_NAME,,}" == "all" ]]; then
    list_postgrescluster_names "$NAMESPACE"
  else
    echo "$POSTGRESCLUSTER_NAME"
  fi
}

while IFS= read -r cluster_name; do
  [[ -z "$cluster_name" ]] && continue

  cr_json=$(get_postgrescluster_json "$NAMESPACE" "$cluster_name" || true)
  [[ -z "$cr_json" ]] && continue

  dps=$(echo "$cr_json" | jq -r '(.spec.proxy.pgBouncer.config.global // {}).default_pool_size // empty' | head -1)
  mcc=$(echo "$cr_json" | jq -r '(.spec.proxy.pgBouncer.config.global // {}).max_client_conn // empty' | head -1)
  mdb=$(echo "$cr_json" | jq -r '(.spec.proxy.pgBouncer.config.global // {}).max_db_connections // empty' | head -1)

  dps_i=$(to_int "$dps")
  mcc_i=$(to_int "$mcc")
  mdb_i=$(to_int "$mdb")

  # If max_db_connections is set and smaller than default_pool_size, backends cannot satisfy pool sizing.
  if [[ -n "$mdb_i" && -n "$dps_i" && "$mdb_i" -lt "$dps_i" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "max_db_connections below default_pool_size for \`${cluster_name}\`" \
      --arg details "max_db_connections=${mdb_i}, default_pool_size=${dps_i} (per-database server connection cap vs pool width)" \
      --arg next_steps "Raise max_db_connections or lower default_pool_size so PgBouncer can open enough server connections" \
      '. += [{"title": $title, "details": $details, "severity": 3, "next_steps": $next_steps}]')
  fi

  # max_client_conn should generally be >= default_pool_size when both are set (sanity).
  if [[ -n "$mcc_i" && -n "$dps_i" && "$mcc_i" -lt "$dps_i" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "max_client_conn smaller than default_pool_size for \`${cluster_name}\`" \
      --arg details "max_client_conn=${mcc_i}, default_pool_size=${dps_i}" \
      --arg next_steps "Review PgBouncer global settings: inbound client cap should not be below pool size without intent" \
      '. += [{"title": $title, "details": $details, "severity": 2, "next_steps": $next_steps}]')
  fi

done < <(resolve_cluster_names)

echo "$issues_json" > "$OUTPUT_FILE"
echo "Connection limits validation completed. Issues written to $OUTPUT_FILE"
