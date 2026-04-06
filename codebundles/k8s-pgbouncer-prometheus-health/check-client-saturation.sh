#!/usr/bin/env bash
set -euo pipefail
set -x
# Compares client active (+ optional waiting) to max_client_conn per pod.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/prom-common.sh"

: "${PROMETHEUS_URL:?}"
: "${PGBOUNCER_JOB_LABEL:?}"

OUTPUT_FILE="client_saturation_analysis.json"
issues_json='[]'
THRESH="${CLIENT_SATURATION_PERCENT_THRESHOLD:-80}"

INNER="$(prom_label_inner)"
# Per-pod utilization: (active+waiting) / max_client_conn for that exporter
Q="(
  sum by (pod, instance) (pgbouncer_pools_client_active_connections{${INNER}})
  + sum by (pod, instance) (pgbouncer_pools_client_waiting_connections{${INNER}})
) / clamp_min(
  max by (pod, instance) (pgbouncer_config_max_client_connections{${INNER}}),
  1
)"

echo "Evaluating client saturation (threshold ${THRESH}%)"

if ! resp="$(prom_instant_query "$Q")"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus Query Failed for Client Saturation" \
    --arg details "Network or curl error querying ${PROMETHEUS_URL}" \
    --arg severity "4" \
    --arg next_steps "Verify Prometheus URL and authentication." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

if ! prom_check_api "$resp"; then
  err=$(echo "$resp" | jq -r '.error // "unknown"' 2>/dev/null || true)
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus API Error (client saturation)" \
    --arg details "$err" \
    --arg severity "3" \
    --arg next_steps "If pod/instance labels are missing, adjust PGBOUNCER_JOB_LABEL or add recording rules. Ensure pgbouncer_pools_* and pgbouncer_config_max_client_connections exist." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

thr_dec=$(awk "BEGIN { printf \"%.4f\", (${THRESH}/100.0) }")

mapfile -t rows < <(echo "$resp" | jq -c '.data.result[]?')
for row in "${rows[@]}"; do
  val=$(echo "$row" | jq -r '.value[1] // "0"')
  pod=$(echo "$row" | jq -r '.metric.pod // "unknown"')
  inst=$(echo "$row" | jq -r '.metric.instance // "unknown"')
  if awk -v v="$val" -v t="$thr_dec" 'BEGIN { exit !(v+0 > t+0) }'; then
    pct=$(awk -v v="$val" 'BEGIN { printf "%.1f", v*100 }')
    issues_json=$(echo "$issues_json" | jq \
      --arg title "High PgBouncer Client Saturation (\`pod=${pod}\`)" \
      --arg details "Estimated utilization ${pct}% (threshold ${THRESH}%). Ratio uses active+waiting vs pgbouncer_config_max_client_connections for instance ${inst}." \
      --arg severity "3" \
      --arg next_steps "Raise max_client_conn, add PgBouncer replicas, reduce app pool sizes, or investigate connection leaks." \
      '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  fi
done

echo "$issues_json" > "$OUTPUT_FILE"
echo "Results written to $OUTPUT_FILE"
jq . "$OUTPUT_FILE"
