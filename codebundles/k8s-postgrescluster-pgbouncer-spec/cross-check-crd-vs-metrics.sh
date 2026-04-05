#!/usr/bin/env bash
set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# OPTIONAL: PROMETHEUS_URL, PROMETHEUS_LABEL_SELECTOR (e.g. namespace="ns",postgrescluster="hippo")
# REQUIRED for meaningful check: CONTEXT, NAMESPACE, POSTGRESCLUSTER_NAME
# Writes: metrics_crosscheck_issues.json
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${POSTGRESCLUSTER_NAME:?Must set POSTGRESCLUSTER_NAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib-pgbouncer-spec.sh"

OUTPUT_FILE="metrics_crosscheck_issues.json"
issues_json='[]'
PROMETHEUS_URL="${PROMETHEUS_URL:-}"
PROMETHEUS_LABEL_SELECTOR="${PROMETHEUS_LABEL_SELECTOR:-}"
METRIC_NAME="${PROMETHEUS_MAX_CLIENT_CONN_METRIC:-pgbouncer_config_max_client_connections}"

resolve_cluster_names() {
  if [[ "${POSTGRESCLUSTER_NAME,,}" == "all" ]]; then
    list_postgrescluster_names "$NAMESPACE"
  else
    echo "$POSTGRESCLUSTER_NAME"
  fi
}

if [[ -z "$PROMETHEUS_URL" ]]; then
  echo '[]' > "$OUTPUT_FILE"
  echo "PROMETHEUS_URL not set; skipping Prometheus cross-check (empty issues)."
  exit 0
fi

# Trim trailing slash
PROMETHEUS_URL="${PROMETHEUS_URL%/}"

while IFS= read -r cluster_name; do
  [[ -z "$cluster_name" ]] && continue

  cr_json=$(get_postgrescluster_json "$NAMESPACE" "$cluster_name" || true)
  [[ -z "$cr_json" ]] && continue

  cr_max=$(echo "$cr_json" | jq -r '(.spec.proxy.pgBouncer.config.global // {}).max_client_conn // empty' | head -1)
  cr_max=$(echo "$cr_max" | tr -d '[:space:]')
  [[ -z "$cr_max" || "$cr_max" == "null" ]] && continue

  if [[ -z "$PROMETHEUS_LABEL_SELECTOR" ]]; then
    echo "Skipping cross-check for ${cluster_name}: set PROMETHEUS_LABEL_SELECTOR to match exporter series" >&2
    continue
  fi

  # Instant query: metric{selector}
  query="${METRIC_NAME}{${PROMETHEUS_LABEL_SELECTOR}}"
  resp=$(curl -fsS -G "${PROMETHEUS_URL}/api/v1/query" --data-urlencode "query=${query}" 2>/dev/null || echo '{"status":"error"}')

  prom_val=$(echo "$resp" | jq -r '.data.result[0].value[1] // empty' 2>/dev/null || echo "")

  if [[ -z "$prom_val" || "$prom_val" == "null" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Prometheus sample missing for max_client_conn (\`${cluster_name}\`)" \
      --arg details "Query returned no series for ${query}" \
      --arg next_steps "Verify ServiceMonitor scrape, metric name, and PROMETHEUS_LABEL_SELECTOR labels" \
      '. += [{"title": $title, "details": $details, "severity": 2, "next_steps": $next_steps}]')
    continue
  fi

  # shellcheck disable=SC2072
  if [[ "$(echo "$cr_max" | tr -d '\n')" != "$(echo "$prom_val" | tr -d '\n')" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "CRD vs Prometheus drift for max_client_conn (\`${cluster_name}\`)" \
      --arg details "CR max_client_conn=${cr_max}, metric=${prom_val} (${METRIC_NAME})" \
      --arg next_steps "Reconcile GitOps source of truth with live cluster; check for recent ConfigMap/PgBouncer reload" \
      '. += [{"title": $title, "details": $details, "severity": 3, "next_steps": $next_steps}]')
  fi

done < <(resolve_cluster_names)

echo "$issues_json" > "$OUTPUT_FILE"
echo "Cross-check completed. Issues written to $OUTPUT_FILE"
