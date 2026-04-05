#!/usr/bin/env bash
set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# REQUIRED ENV: CONTEXT, NAMESPACE, POSTGRESCLUSTER_NAME, KUBERNETES_DISTRIBUTION_BINARY (optional)
# Writes: fetch_issues.json (JSON array of issues), prints PgBouncer spec excerpt to stdout
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${POSTGRESCLUSTER_NAME:?Must set POSTGRESCLUSTER_NAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-pgbouncer-spec.sh"

OUTPUT_FILE="fetch_issues.json"
issues_json='[]'

resolve_cluster_names() {
  local mode="$1"
  if [[ "${mode,,}" == "all" ]]; then
    list_postgrescluster_names "$NAMESPACE"
  else
    echo "$mode"
  fi
}

while IFS= read -r cluster_name; do
  [[ -z "$cluster_name" ]] && continue

  if ! cr_json=$(get_postgrescluster_json "$NAMESPACE" "$cluster_name"); then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Cannot read PostgresCluster \`${cluster_name}\`" \
      --arg details "kubectl get postgrescluster failed for ${NAMESPACE}/${cluster_name}" \
      --arg next_steps "Verify kubeconfig, context, RBAC (get postgresclusters), and namespace" \
      '. += [{
        "title": $title,
        "details": $details,
        "severity": 2,
        "next_steps": $next_steps
      }]')
    continue
  fi

  if ! echo "$cr_json" | jq -e '.spec.proxy.pgBouncer' >/dev/null 2>&1; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "PgBouncer proxy not configured for \`${cluster_name}\`" \
      --arg details "spec.proxy.pgBouncer is absent on PostgresCluster ${NAMESPACE}/${cluster_name}" \
      --arg next_steps "Enable connection pooling: set spec.proxy.pgBouncer in the PostgresCluster CR" \
      '. += [{
        "title": $title,
        "details": $details,
        "severity": 2,
        "next_steps": $next_steps
      }]')
  fi

  echo "--- PostgresCluster ${NAMESPACE}/${cluster_name} (spec.proxy.pgBouncer) ---"
  echo "$cr_json" | jq -c '.spec.proxy.pgBouncer // {"note":"null"}'

done < <(resolve_cluster_names "$POSTGRESCLUSTER_NAME")

echo "$issues_json" > "$OUTPUT_FILE"
echo "Fetch completed. Issues written to $OUTPUT_FILE"
