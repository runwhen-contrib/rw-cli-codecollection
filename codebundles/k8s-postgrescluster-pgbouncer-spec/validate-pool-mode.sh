#!/usr/bin/env bash
set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# REQUIRED: CONTEXT, NAMESPACE, POSTGRESCLUSTER_NAME, EXPECTED_POOL_MODE
# OUTPUT: pool_mode_issues.json
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-pgbouncer-spec.sh
source "${SCRIPT_DIR}/lib-pgbouncer-spec.sh"

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${POSTGRESCLUSTER_NAME:?Must set POSTGRESCLUSTER_NAME}"
: "${EXPECTED_POOL_MODE:?Must set EXPECTED_POOL_MODE}"

OUTPUT_FILE="pool_mode_issues.json"
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

expected_norm="$(echo "${EXPECTED_POOL_MODE}" | tr '[:upper:]' '[:lower:]')"

while IFS= read -r cluster_name; do
  [ -z "$cluster_name" ] && continue

  if ! raw_json="$(fetch_cluster_json "$cluster_name")" || [ -z "$raw_json" ]; then
    append_issue \
      "Cannot read PostgresCluster for pool mode check: \`${cluster_name}\`" \
      "kubectl get failed." \
      4 \
      "Verify kube access and resource name."
    continue
  fi

  if [ "$(echo "$raw_json" | jq 'if (.spec.proxy.pgBouncer != null) then true else false end')" != "true" ]; then
    append_issue \
      "Pool mode check skipped (no PgBouncer): \`${cluster_name}\`" \
      "spec.proxy.pgBouncer is not configured." \
      2 \
      "Configure PgBouncer or set EXPECTED_POOL_MODE only when proxy is enabled."
    continue
  fi

  pool_raw="$(global_setting_alt "$raw_json" "pool_mode")"
  if [ -z "$pool_raw" ] || [ "$pool_raw" = "null" ]; then
    append_issue \
      "pool_mode not set in PgBouncer global config for \`${cluster_name}\`" \
      "Expected pool_mode (transaction|session|statement) in spec.proxy.pgBouncer.config.global." \
      2 \
      "Set global.pool_mode in PostgresCluster to match workload (often transaction for server-side pooling/ORMs)."
    continue
  fi

  pool_norm="$(echo "$pool_raw" | tr '[:upper:]' '[:lower:]')"
  if [ "$pool_norm" != "$expected_norm" ]; then
    append_issue \
      "pool_mode mismatch for \`${cluster_name}\`" \
      "Found pool_mode=${pool_raw}; policy EXPECTED_POOL_MODE=${EXPECTED_POOL_MODE}." \
      3 \
      "Update spec.proxy.pgBouncer.config.global.pool_mode to ${EXPECTED_POOL_MODE} or adjust policy if intentional."
  fi
done < <(list_postgrescluster_names)

echo "$issues_json" > "$OUTPUT_FILE"
echo "Pool mode validation wrote ${OUTPUT_FILE}"
