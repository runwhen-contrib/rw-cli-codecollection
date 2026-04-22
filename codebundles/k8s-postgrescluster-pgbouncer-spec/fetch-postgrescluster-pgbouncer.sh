#!/usr/bin/env bash
set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# REQUIRED ENV: CONTEXT, NAMESPACE, POSTGRESCLUSTER_NAME (or All), KUBECONFIG
# OUTPUT: fetch_pgbouncer_issues.json (array), human summary on stdout
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-pgbouncer-spec.sh
source "${SCRIPT_DIR}/lib-pgbouncer-spec.sh"

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${POSTGRESCLUSTER_NAME:?Must set POSTGRESCLUSTER_NAME}"

OUTPUT_FILE="fetch_pgbouncer_issues.json"
issues_json='[]'
mode_lc="$(echo "${POSTGRESCLUSTER_NAME}" | tr '[:upper:]' '[:lower:]')"

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
  echo "=== PostgresCluster: ${cluster_name} (namespace ${NAMESPACE}) ==="

  if ! raw_json="$(fetch_cluster_json "$cluster_name")" || [ -z "$raw_json" ]; then
    append_issue \
      "Cannot read PostgresCluster \`${cluster_name}\`" \
      "kubectl get ${PG_CRD} failed or returned empty in namespace ${NAMESPACE}." \
      4 \
      "Verify RBAC (get on postgresclusters), context ${CONTEXT}, and resource name."
    echo "---"
    continue
  fi

  has_proxy="$(echo "$raw_json" | jq 'if (.spec.proxy.pgBouncer != null) then true else false end')"
  if [ "$has_proxy" != "true" ]; then
    append_issue \
      "PgBouncer proxy not defined for \`${cluster_name}\`" \
      "spec.proxy.pgBouncer is absent; this bundle audits PgBouncer settings only." \
      2 \
      "Enable spec.proxy.pgBouncer in PostgresCluster or remove this SLX if pooling is not used."
    echo "---"
    echo "PgBouncer block: not present in spec"
    echo ""
    continue
  fi

  global_json="$(echo "$raw_json" | jq -c '.spec.proxy.pgBouncer.config.global // {}' 2>/dev/null || echo '{}')"
  replicas="$(echo "$raw_json" | jq -r '.spec.proxy.pgBouncer.replicas // empty' 2>/dev/null || true)"
  pool="$(global_setting_alt "$raw_json" "pool_mode")"
  dps="$(global_setting_alt "$raw_json" "default_pool_size")"
  mcc="$(global_setting_alt "$raw_json" "max_client_conn")"
  mdb="$(global_setting_alt "$raw_json" "max_db_connections")"

  echo "spec.proxy.pgBouncer.replicas: ${replicas:-<default>}"
  echo "global.pool_mode: ${pool:-<unset>}"
  echo "global.default_pool_size: ${dps:-<unset>}"
  echo "global.max_client_conn: ${mcc:-<unset>}"
  echo "global.max_db_connections: ${mdb:-<unset>}"
  echo "global (raw keys): $(echo "$global_json" | jq -r 'keys | join(", ")' 2>/dev/null || echo "{}")"
  echo ""
done < <(list_postgrescluster_names)

if [ "$mode_lc" = "all" ]; then
  cnt="$(${KUBECTL} get "$PG_CRD" -n "${NAMESPACE}" --context "${CONTEXT}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${cnt:-0}" -eq 0 ] 2>/dev/null; then
    append_issue \
      "No PostgresCluster resources in namespace \`${NAMESPACE}\`" \
      "Discovery (POSTGRESCLUSTER_NAME=All) found zero ${PG_CRD} objects." \
      1 \
      "Create a PostgresCluster or scope POSTGRESCLUSTER_NAME to a specific cluster."
  fi
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Fetch completed. Issues JSON: ${OUTPUT_FILE}"
