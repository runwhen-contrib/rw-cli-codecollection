#!/usr/bin/env bash
set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# Optional: PROMETHEUS_URL — compares CR max_client_conn to Prometheus sample.
# OUTPUT: cross_check_issues.json
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-pgbouncer-spec.sh
source "${SCRIPT_DIR}/lib-pgbouncer-spec.sh"

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${POSTGRESCLUSTER_NAME:?Must set POSTGRESCLUSTER_NAME}"

OUTPUT_FILE="cross_check_issues.json"
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

PROM_URL="${PROMETHEUS_URL:-}"

if [ -z "$PROM_URL" ] || [ "$PROM_URL" = "disabled" ]; then
  echo '[]' > "$OUTPUT_FILE"
  echo "Cross-check skipped (PROMETHEUS_URL not set)."
  exit 0
fi

# Trim trailing slash
PROM_URL="${PROM_URL%/}"

while IFS= read -r cluster_name; do
  [ -z "$cluster_name" ] && continue

  if ! raw_json="$(fetch_cluster_json "$cluster_name")" || [ -z "$raw_json" ]; then
    append_issue \
      "Cross-check skipped (no CR) for \`${cluster_name}\`" \
      "Could not load PostgresCluster JSON." \
      2 \
      "Fix kubectl access before relying on Prometheus cross-check."
    continue
  fi

  if [ "$(echo "$raw_json" | jq 'if (.spec.proxy.pgBouncer != null) then true else false end')" != "true" ]; then
    continue
  fi

  cr_max="$(numeric_or_empty "$(global_setting_alt "$raw_json" "max_client_conn")")"
  if [ -z "$cr_max" ]; then
    append_issue \
      "Cross-check skipped for \`${cluster_name}\`" \
      "max_client_conn not set in CR global config; nothing to compare to metrics." \
      1 \
      "Set max_client_conn in spec.proxy.pgBouncer.config.global or ignore this informational finding."
    continue
  fi

  # PromQL: max metric in namespace; optional extra labels from PROMETHEUS_EXTRA_LABELS e.g. pod=~\".*cluster-.*
  extra="${PROMETHEUS_EXTRA_LABELS:-}"
  if [ -n "$extra" ]; then
    promql="max(pgbouncer_config_max_client_connections{namespace=\"${NAMESPACE}\",${extra}})"
  else
    promql="max(pgbouncer_config_max_client_connections{namespace=\"${NAMESPACE}\"})"
  fi

  resp="$(curl -sS -G "${PROM_URL}/api/v1/query" --data-urlencode "query=${promql}" 2>/dev/null || echo '{"status":"error"}')"
  status="$(echo "$resp" | jq -r '.status // "error"')"

  if [ "$status" != "success" ]; then
    append_issue \
      "Prometheus query failed for \`${cluster_name}\`" \
      "Could not evaluate: ${promql}. Response snippet: $(echo "$resp" | jq -c . 2>/dev/null | head -c 400)" \
      2 \
      "Verify PROMETHEUS_URL, network access, and that pgbouncer_exporter metrics exist for this namespace."
    continue
  fi

  metric_val="$(echo "$resp" | jq -r '([.data.result[]?.value[1]? | tonumber] | max) // empty' 2>/dev/null || true)"

  if [ -z "$metric_val" ] || [ "$metric_val" = "null" ]; then
    append_issue \
      "No Prometheus samples for pgbouncer_config_max_client_connections (namespace \`${NAMESPACE}\`)" \
      "Query returned empty series for cluster \`${cluster_name}\`." \
      2 \
      "Confirm ServiceMonitor/PodMonitor scrapes PgBouncer metrics; adjust PROMETHEUS_EXTRA_LABELS if needed."
    continue
  fi

  m_int="$(printf '%.0f' "$metric_val" 2>/dev/null || echo "$metric_val")"
  if [ "$m_int" != "$cr_max" ]; then
    append_issue \
      "CR vs metrics drift for max_client_conn on \`${cluster_name}\`" \
      "CR max_client_conn=${cr_max}; Prometheus pgbouncer_config_max_client_connections=${metric_val} (instant max in namespace)." \
      3 \
      "Reconcile GitOps/CR with running ConfigMap or exporter; ensure single source of truth for pool limits."
  fi
done < <(list_postgrescluster_names)

echo "$issues_json" > "$OUTPUT_FILE"
echo "Cross-check wrote ${OUTPUT_FILE}"
