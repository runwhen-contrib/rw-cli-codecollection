#!/usr/bin/env bash
set -euo pipefail
set -x
# REQUIRED: CONTEXT, NAMESPACE, POSTGRESCLUSTER_NAME
# Optional: MIN_PGBOUNCER_REPLICAS (default 1)
# Output: replica_issues.json

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${POSTGRESCLUSTER_NAME:?Must set POSTGRESCLUSTER_NAME}"

MIN_REP="${MIN_PGBOUNCER_REPLICAS:-1}"
KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
CRD="postgresclusters.postgres-operator.crunchydata.com"
OUTPUT_FILE="replica_issues.json"
issues_json='[]'

list_clusters() {
  if [[ "${POSTGRESCLUSTER_NAME,,}" == "all" ]]; then
    "${KUBECTL}" get "$CRD" -n "$NAMESPACE" --context "$CONTEXT" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
  else
    echo "$POSTGRESCLUSTER_NAME"
  fi
}

check_one() {
  local name="$1"
  local cr_json spec_rep ready dep_rep
  if ! cr_json=$("${KUBECTL}" get "$CRD" "$name" -n "$NAMESPACE" --context "$CONTEXT" -o json 2>/dev/null); then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Cannot read PostgresCluster \`$name\` for replica check" \
      --arg details "kubectl get failed" \
      --argjson severity 2 \
      --arg next_steps "Verify RBAC and resource name." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
    return
  fi

  if ! echo "$cr_json" | jq -e '.spec.proxy.pgBouncer' >/dev/null 2>&1; then
    echo "PostgresCluster $name: no PgBouncer spec; skipping replica policy check."
    return
  fi

  spec_rep=$(echo "$cr_json" | jq -r '.spec.proxy.pgBouncer.replicas // empty')
  ready=$(echo "$cr_json" | jq -r '.status.proxy.pgBouncer.readyReplicas // empty')

  # Fallback: count pgbouncer pods for this cluster
  dep_rep=$("${KUBECTL}" get pods -n "$NAMESPACE" --context "$CONTEXT" \
    -l "postgres-operator.crunchydata.com/cluster=${name},postgres-operator.crunchydata.com/role=pgbouncer" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')

  local effective
  if [[ -n "$ready" && "$ready" != "null" && "$ready" != "" ]]; then
    effective=$ready
  elif [[ -n "$spec_rep" && "$spec_rep" != "null" ]]; then
    effective=$spec_rep
  else
    effective=$dep_rep
  fi

  echo "PostgresCluster $name: spec.replicas=${spec_rep:-n/a} status.readyReplicas=${ready:-n/a} pgbouncer pods=${dep_rep}"

  if ! [[ "$effective" =~ ^[0-9]+$ ]] || [[ "$effective" == "0" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "PgBouncer replicas not observed for \`$name\`" \
      --arg details "Could not determine ready replicas (status may be empty and no pgbouncer pods found)." \
      --argjson severity 2 \
      --arg next_steps "Confirm PgBouncer is deployed and status.proxy.pgBouncer is populated." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
    return
  fi

  if [[ "$effective" -lt "$MIN_REP" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "PgBouncer replica count below policy for \`$name\`" \
      --arg details "Effective replicas=$effective; MIN_PGBOUNCER_REPLICAS=$MIN_REP." \
      --argjson severity 2 \
      --arg next_steps "Increase spec.proxy.pgBouncer.replicas or fix scheduling so at least $MIN_REP instances run for HA." \
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
