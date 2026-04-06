#!/usr/bin/env bash
set -euo pipefail
set -x
# Optional: PROMETHEUS_URL — if unset, writes empty issues and exits 0.
# REQUIRED when PROMETHEUS_URL set: CONTEXT, NAMESPACE, POSTGRESCLUSTER_NAME
# Compares CR max_client_conn to instant query pgbouncer_config_max_client_connections when possible.
# Output: prometheus_crosscheck_issues.json

OUTPUT_FILE="prometheus_crosscheck_issues.json"
issues_json='[]'

if [[ -z "${PROMETHEUS_URL:-}" ]]; then
  echo "PROMETHEUS_URL not set; skipping Prometheus cross-check (best-effort)."
  echo '[]' | jq . >"$OUTPUT_FILE"
  exit 0
fi

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${POSTGRESCLUSTER_NAME:?Must set POSTGRESCLUSTER_NAME}"

KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
CRD="postgresclusters.postgres-operator.crunchydata.com"
PROM="${PROMETHEUS_URL%/}"

first_key() {
  local json="$1"
  local key="$2"
  echo "$json" | jq -r --arg k "$key" '.. | objects | select(has($k)) | .[$k] | tostring' | head -1
}

to_int() {
  local v="$1"
  [[ -z "$v" ]] && echo "" && return
  echo "$v" | tr -cd '0-9'
}

list_clusters() {
  if [[ "${POSTGRESCLUSTER_NAME,,}" == "all" ]]; then
    "${KUBECTL}" get "$CRD" -n "$NAMESPACE" --context "$CONTEXT" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
  else
    echo "$POSTGRESCLUSTER_NAME"
  fi
}

check_one() {
  local name="$1"
  local cr_json cfg_json mcc mcc_i
  if ! cr_json=$("${KUBECTL}" get "$CRD" "$name" -n "$NAMESPACE" --context "$CONTEXT" -o json 2>/dev/null); then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Cannot read PostgresCluster \`$name\` for Prometheus cross-check" \
      --arg details "kubectl get failed" \
      --argjson severity 2 \
      --arg next_steps "Fix Kubernetes access before comparing to metrics." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
    return
  fi

  cfg_json=$(echo "$cr_json" | jq -c '.spec.proxy.pgBouncer.config // {}')
  mcc=$(first_key "$cfg_json" "max_client_conn")
  mcc_i=$(to_int "$mcc")
  if [[ -z "$mcc_i" ]]; then
    echo "PostgresCluster $name: max_client_conn not found in CR config; skipping metric compare."
    return
  fi

  # Metric query: filter by namespace and cluster name when labels exist
  local query resp val
  query="max(pgbouncer_config_max_client_connections{namespace=\"${NAMESPACE}\",postgres_cluster=\"${name}\"})"
  if ! resp=$(curl -fsS --max-time 30 -G "${PROM}/api/v1/query" --data-urlencode "query=${query}" 2>/dev/null); then
    query="max(pgbouncer_config_max_client_connections{namespace=\"${NAMESPACE}\"})"
    resp=$(curl -fsS --max-time 30 -G "${PROM}/api/v1/query" --data-urlencode "query=${query}" 2>/dev/null) || true
  fi

  val=$(echo "$resp" | jq -r '.data.result[0].value[1] // empty' 2>/dev/null || true)
  if [[ -z "$val" || "$val" == "null" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Prometheus metric missing for \`$name\`" \
      --arg details "Could not read pgbouncer_config_max_client_connections from $PROM (query may need different labels)." \
      --argjson severity 2 \
      --arg next_steps "Adjust PromQL labels to match your ServiceMonitor; cross-check is best-effort." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
    return
  fi

  local val_i
  val_i=$(to_int "$val")
  echo "PostgresCluster $name: CR max_client_conn=$mcc_i metric=$val_i"

  if [[ "$val_i" != "$mcc_i" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "CR vs Prometheus max_client_conn drift for \`$name\`" \
      --arg details "CR declares max_client_conn=$mcc_i but metric sample=$val_i." \
      --argjson severity 3 \
      --arg next_steps "Reconcile GitOps/CR with running PgBouncer; restart or fix config rollout if drift is unintended." \
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
