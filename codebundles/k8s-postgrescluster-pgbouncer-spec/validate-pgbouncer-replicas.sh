#!/usr/bin/env bash
set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# REQUIRED: CONTEXT, NAMESPACE, POSTGRESCLUSTER_NAME
# OPTIONAL: MIN_PGBOUNCER_REPLICAS (default 1)
# Writes: replica_issues.json
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${POSTGRESCLUSTER_NAME:?Must set POSTGRESCLUSTER_NAME}"

MIN_PGBOUNCER_REPLICAS="${MIN_PGBOUNCER_REPLICAS:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-pgbouncer-spec.sh"

KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
OUTPUT_FILE="replica_issues.json"
issues_json='[]'

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

  desired=$(echo "$cr_json" | jq -r '.spec.proxy.pgBouncer.replicas // empty')
  ready=$(echo "$cr_json" | jq -r '.status.proxy.pgBouncer.readyReplicas // empty')

  dep_ready=$("$KUBECTL" get deploy -n "$NAMESPACE" --context "$CONTEXT" \
    -l "postgres-operator.crunchydata.com/cluster=${cluster_name},postgres-operator.crunchydata.com/role=pgbouncer" \
    -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo "")

  effective="${ready:-$dep_ready}"
  [[ -z "$effective" || "$effective" == "null" ]] && effective="0"

  if [[ "$effective" -lt "$MIN_PGBOUNCER_REPLICAS" ]]; then
    sev=1
    if [[ "${MIN_PGBOUNCER_REPLICAS}" -gt 1 ]]; then
      sev=2
    fi
    issues_json=$(echo "$issues_json" | jq \
      --arg title "PgBouncer replicas below policy for \`${cluster_name}\`" \
      --arg details "readyReplicas/status or Deployment ready=${effective}, MIN_PGBOUNCER_REPLICAS=${MIN_PGBOUNCER_REPLICAS}, spec.replicas=${desired:-unset}" \
      --arg next_steps "Increase spec.proxy.pgBouncer.replicas or fix rollout; for HA use at least 2 replicas where policy requires it" \
      --argjson severity "$sev" \
      '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
  fi

done < <(resolve_cluster_names)

echo "$issues_json" > "$OUTPUT_FILE"
echo "Replica validation completed. Issues written to $OUTPUT_FILE"
