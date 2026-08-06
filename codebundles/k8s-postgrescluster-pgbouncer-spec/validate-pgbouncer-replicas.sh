#!/usr/bin/env bash
set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# REQUIRED: MIN_PGBOUNCER_REPLICAS (default 1)
# OUTPUT: pgbouncer_replicas_issues.json
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-pgbouncer-spec.sh
source "${SCRIPT_DIR}/lib-pgbouncer-spec.sh"

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${POSTGRESCLUSTER_NAME:?Must set POSTGRESCLUSTER_NAME}"

MIN_R="${MIN_PGBOUNCER_REPLICAS:-1}"
if ! [[ "$MIN_R" =~ ^[0-9]+$ ]]; then
  MIN_R=1
fi

OUTPUT_FILE="pgbouncer_replicas_issues.json"
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
      "Cannot read PostgresCluster for replica check: \`${cluster_name}\`" \
      "kubectl get failed." \
      4 \
      "Verify kube access."
    continue
  fi

  if [ "$(echo "$raw_json" | jq 'if (.spec.proxy.pgBouncer != null) then true else false end')" != "true" ]; then
    continue
  fi

  spec_rep="$(echo "$raw_json" | jq -r '.spec.proxy.pgBouncer.replicas // empty')"
  ready_rep="$(echo "$raw_json" | jq -r '.status.proxy.pgBouncer.readyReplicas // empty')"
  stat_rep="$(echo "$raw_json" | jq -r '.status.proxy.pgBouncer.replicas // empty')"

  echo "cluster=${cluster_name} spec.replicas=${spec_rep:-<default>} status.replicas=${stat_rep:-?} status.readyReplicas=${ready_rep:-?}"

  effective_spec="$spec_rep"
  if [ -z "$effective_spec" ] || [ "$effective_spec" = "null" ]; then
    effective_spec=1
  fi

  if [ "$effective_spec" -lt "$MIN_R" ] 2>/dev/null; then
    append_issue \
      "PgBouncer spec replicas below policy for \`${cluster_name}\`" \
      "spec.proxy.pgBouncer.replicas=${spec_rep:-1} (effective ${effective_spec}); MIN_PGBOUNCER_REPLICAS=${MIN_R}." \
      2 \
      "Raise spec.proxy.pgBouncer.replicas to at least ${MIN_R} for HA, or lower MIN_PGBOUNCER_REPLICAS if single replica is acceptable."
  fi

  if [ -n "$ready_rep" ] && [ "$ready_rep" != "null" ] && [ "$ready_rep" -lt "$MIN_R" ] 2>/dev/null; then
    append_issue \
      "PgBouncer ready replicas below policy for \`${cluster_name}\`" \
      "status.proxy.pgBouncer.readyReplicas=${ready_rep}; policy requires MIN_PGBOUNCER_REPLICAS=${MIN_R}." \
      2 \
      "Investigate PgBouncer pods (image pull, scheduling, rollout); restore readiness before production traffic."
  fi
done < <(list_postgrescluster_names)

echo "$issues_json" > "$OUTPUT_FILE"
echo "Replica validation wrote ${OUTPUT_FILE}"
