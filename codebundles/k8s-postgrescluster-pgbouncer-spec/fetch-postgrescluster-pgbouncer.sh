#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS: CONTEXT, NAMESPACE, POSTGRESCLUSTER_NAME
# Optional: KUBERNETES_DISTRIBUTION_BINARY (default kubectl)
# Writes JSON array of issues to fetch_pgbouncer_issues.json
# Prints human summary to stdout for the report.
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${POSTGRESCLUSTER_NAME:?Must set POSTGRESCLUSTER_NAME}"

KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
CRD="postgresclusters.postgres-operator.crunchydata.com"
OUTPUT_FILE="fetch_pgbouncer_issues.json"
issues_json='[]'

list_clusters() {
  if [[ "${POSTGRESCLUSTER_NAME,,}" == "all" ]]; then
    "${KUBECTL}" get "$CRD" -n "$NAMESPACE" --context "$CONTEXT" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
  else
    echo "$POSTGRESCLUSTER_NAME"
  fi
}

summarize_one() {
  local name="$1"
  local cr_json
  if ! cr_json=$("${KUBECTL}" get "$CRD" "$name" -n "$NAMESPACE" --context "$CONTEXT" -o json 2>/dev/null); then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Cannot read PostgresCluster \`$name\`" \
      --arg details "kubectl get $CRD failed for $name in namespace $NAMESPACE" \
      --argjson severity 2 \
      --arg next_steps "Verify RBAC allows get on $CRD and that the resource name and namespace are correct." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
    return
  fi

  local pgb
  pgb=$(echo "$cr_json" | jq -c '.spec.proxy.pgBouncer // empty')
  if [[ -z "$pgb" || "$pgb" == "null" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "PgBouncer block missing on PostgresCluster \`$name\`" \
      --arg details "spec.proxy.pgBouncer is not set; proxy pooling is not declared in this CR." \
      --argjson severity 2 \
      --arg next_steps "If PgBouncer is required, add spec.proxy.pgBouncer to the PostgresCluster manifest." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  fi

  echo "=== PostgresCluster: $name (namespace $NAMESPACE) ==="
  echo "$cr_json" | jq '{poolMode: .spec.proxy.pgBouncer.poolMode, replicas: .spec.proxy.pgBouncer.replicas, config: .spec.proxy.pgBouncer.config, status: .status.proxy.pgBouncer}'
}

while IFS= read -r cluster_name; do
  [[ -z "$cluster_name" ]] && continue
  summarize_one "$cluster_name"
done < <(list_clusters)

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
exit 0
