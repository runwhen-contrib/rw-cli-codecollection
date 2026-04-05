#!/usr/bin/env bash
set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# REQUIRED: CONTEXT, NAMESPACE, POSTGRESCLUSTER_NAME, EXPECTED_POOL_MODE
# Writes: pool_mode_issues.json
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${POSTGRESCLUSTER_NAME:?Must set POSTGRESCLUSTER_NAME}"
: "${EXPECTED_POOL_MODE:?Must set EXPECTED_POOL_MODE}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-pgbouncer-spec.sh"

OUTPUT_FILE="pool_mode_issues.json"
issues_json='[]'

expected_norm=$(echo "$EXPECTED_POOL_MODE" | tr '[:upper:]' '[:lower:]')

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
  if [[ -z "$cr_json" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Cannot read PostgresCluster for pool mode \`${cluster_name}\`" \
      --arg details "kubectl get failed" \
      --arg next_steps "Fix cluster access and retry" \
      '. += [{"title": $title, "details": $details, "severity": 3, "next_steps": $next_steps}]')
    continue
  fi

  pool_raw=$(echo "$cr_json" | jq -r '
    (.spec.proxy.pgBouncer.config.global // {}) as $g |
    ($g.pool_mode // $g.poolMode // "") | tostring
  ')

  if [[ -z "$pool_raw" || "$pool_raw" == "null" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "pool_mode not set in PgBouncer global config for \`${cluster_name}\`" \
      --arg details "Expected pool_mode under spec.proxy.pgBouncer.config.global (e.g. transaction)" \
      --arg next_steps "Set pool_mode in spec.proxy.pgBouncer.config.global to match workload (ORMs often need transaction)" \
      '. += [{"title": $title, "details": $details, "severity": 2, "next_steps": $next_steps}]')
    continue
  fi

  pool_norm=$(echo "$pool_raw" | tr '[:upper:]' '[:lower:]')
  if [[ "$pool_norm" != "$expected_norm" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "PgBouncer pool_mode mismatch for \`${cluster_name}\`" \
      --arg details "Found pool_mode=${pool_raw}, EXPECTED_POOL_MODE=${EXPECTED_POOL_MODE}" \
      --arg next_steps "Align spec.proxy.pgBouncer.config.global.pool_mode with policy (e.g. transaction for many ORMs)" \
      '. += [{"title": $title, "details": $details, "severity": 3, "next_steps": $next_steps}]')
  fi

done < <(resolve_cluster_names)

echo "$issues_json" > "$OUTPUT_FILE"
echo "Pool mode validation completed. Issues written to $OUTPUT_FILE"
