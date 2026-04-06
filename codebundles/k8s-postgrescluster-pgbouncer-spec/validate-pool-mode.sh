#!/usr/bin/env bash
set -euo pipefail
set -x
# REQUIRED: CONTEXT, NAMESPACE, POSTGRESCLUSTER_NAME, EXPECTED_POOL_MODE
# Output: pool_mode_issues.json (JSON array)

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${POSTGRESCLUSTER_NAME:?Must set POSTGRESCLUSTER_NAME}"
: "${EXPECTED_POOL_MODE:?Must set EXPECTED_POOL_MODE}"

KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
CRD="postgresclusters.postgres-operator.crunchydata.com"
OUTPUT_FILE="pool_mode_issues.json"
issues_json='[]'

expected_norm=$(echo "$EXPECTED_POOL_MODE" | tr '[:upper:]' '[:lower:]')

list_clusters() {
  if [[ "${POSTGRESCLUSTER_NAME,,}" == "all" ]]; then
    "${KUBECTL}" get "$CRD" -n "$NAMESPACE" --context "$CONTEXT" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
  else
    echo "$POSTGRESCLUSTER_NAME"
  fi
}

check_one() {
  local name="$1"
  local cr_json pool
  if ! cr_json=$("${KUBECTL}" get "$CRD" "$name" -n "$NAMESPACE" --context "$CONTEXT" -o json 2>/dev/null); then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Cannot read PostgresCluster \`$name\` for pool mode check" \
      --arg details "kubectl get failed" \
      --argjson severity 3 \
      --arg next_steps "Fix kubectl access and verify the cluster exists." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
    return
  fi

  pool=$(echo "$cr_json" | jq -r '.spec.proxy.pgBouncer.poolMode // empty')
  if [[ -z "$pool" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Pool mode not set for PostgresCluster \`$name\`" \
      --arg details "spec.proxy.pgBouncer.poolMode is empty; cannot compare to expected $expected_norm." \
      --argjson severity 2 \
      --arg next_steps "Set spec.proxy.pgBouncer.poolMode to transaction, session, or statement per application needs." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
    return
  fi

  local pool_norm
  pool_norm=$(echo "$pool" | tr '[:upper:]' '[:lower:]')
  if [[ "$pool_norm" != "$expected_norm" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "PgBouncer pool mode mismatch on \`$name\`" \
      --arg details "Configured poolMode is '$pool'; EXPECTED_POOL_MODE is '$EXPECTED_POOL_MODE'." \
      --argjson severity 3 \
      --arg next_steps "Align poolMode with ORM/driver expectations (e.g. transaction for many SQLAlchemy async setups)." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  fi

  echo "PostgresCluster $name: poolMode=$pool (expected $EXPECTED_POOL_MODE)"
}

while IFS= read -r c; do
  [[ -z "$c" ]] && continue
  check_one "$c"
done < <(list_clusters)

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
exit 0
