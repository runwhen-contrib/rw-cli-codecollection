#!/usr/bin/env bash
set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# Validates ordering of default_pool_size vs max_client_conn / max_db_connections.
# OUTPUT: connection_limits_issues.json
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-pgbouncer-spec.sh
source "${SCRIPT_DIR}/lib-pgbouncer-spec.sh"

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${POSTGRESCLUSTER_NAME:?Must set POSTGRESCLUSTER_NAME}"

OUTPUT_FILE="connection_limits_issues.json"
issues_json='[]'

append_issue() {
  local title="$1" details="$2" severity="$3" next_steps="$4"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "$title" \
    --arg details "$details" \
    --argjson severity "$severity" \
    --arg next_steps "$next_steps" \
    '. += [{
      "title": $title,
      "details": $details,
      "severity": $severity,
      "next_steps": $next_steps
    }]')
}

while IFS= read -r cluster_name; do
  [ -z "$cluster_name" ] && continue

  if ! raw_json="$(fetch_cluster_json "$cluster_name")" || [ -z "$raw_json" ]; then
    append_issue \
      "Cannot read PostgresCluster for limits check: \`${cluster_name}\`" \
      "kubectl get failed." \
      4 \
      "Verify kube access."
    continue
  fi

  if [ "$(echo "$raw_json" | jq 'if (.spec.proxy.pgBouncer != null) then true else false end')" != "true" ]; then
    continue
  fi

  dps="$(numeric_or_empty "$(global_setting_alt "$raw_json" "default_pool_size")")"
  mcc="$(numeric_or_empty "$(global_setting_alt "$raw_json" "max_client_conn")")"
  mdb="$(numeric_or_empty "$(global_setting_alt "$raw_json" "max_db_connections")")"

  if [ -n "$mdb" ] && [ -n "$dps" ] && [ "$mdb" -lt "$dps" ]; then
    append_issue \
      "max_db_connections below default_pool_size for \`${cluster_name}\`" \
      "max_db_connections=${mdb} default_pool_size=${dps}; backend limit cannot satisfy pool demand." \
      3 \
      "Increase max_db_connections or lower default_pool_size in PgBouncer global settings."
  fi

  if [ -n "$mcc" ] && [ -n "$dps" ] && [ "$mcc" -lt "$dps" ]; then
    append_issue \
      "max_client_conn lower than default_pool_size for \`${cluster_name}\`" \
      "max_client_conn=${mcc} default_pool_size=${dps}; unusual/risky combination." \
      2 \
      "Review PgBouncer sizing: max_client_conn is usually much larger than per-database pool size."
  fi

  if [ -n "$mcc" ] && [ -n "$mdb" ] && [ -n "$dps" ] && [ "$mdb" -gt 0 ] 2>/dev/null; then
    # Heuristic: if clients can open more slots than backend allows across pools
    if [ "$mcc" -gt "$mdb" ] && [ "$dps" -gt $((mdb / 2)) ] 2>/dev/null; then
      append_issue \
        "Possible saturation risk for \`${cluster_name}\`" \
        "max_client_conn=${mcc} max_db_connections=${mdb} default_pool_size=${dps}; clients may compete for limited backend connections." \
        2 \
        "Align limits with expected client concurrency; consider raising max_db_connections or tuning pool sizes."
    fi
  fi
done < <(list_postgrescluster_names)

echo "$issues_json" > "$OUTPUT_FILE"
echo "Connection limits validation wrote ${OUTPUT_FILE}"
