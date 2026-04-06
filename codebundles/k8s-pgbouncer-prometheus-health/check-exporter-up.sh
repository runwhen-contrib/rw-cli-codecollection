#!/usr/bin/env bash
set -euo pipefail
set -x
# Fails when pgbouncer_up = 0 for any target series (exporter or PgBouncer unavailable).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/prom-common.sh"

: "${PROMETHEUS_URL:?Must set PROMETHEUS_URL}"
: "${PGBOUNCER_JOB_LABEL:?Must set PGBOUNCER_JOB_LABEL}"

OUTPUT_FILE="exporter_up_analysis.json"
issues_json='[]'

INNER="$(prom_label_inner)"
Q="pgbouncer_up{${INNER}}"

echo "Querying Prometheus for pgbouncer_up with matchers: {${INNER}}"

if ! resp="$(prom_instant_query "$Q")"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus Query Failed for \`pgbouncer_up\`" \
    --arg details "curl or network error while querying ${PROMETHEUS_URL}" \
    --arg severity "4" \
    --arg next_steps "Verify PROMETHEUS_URL reachability, TLS, and PROMETHEUS_BEARER_TOKEN if auth is required." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

if ! prom_check_api "$resp"; then
  err=$(echo "$resp" | jq -r '.error // .errorType // "unknown"' 2>/dev/null || echo "parse error")
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus API Error for \`pgbouncer_up\`" \
    --arg details "$err" \
    --arg severity "4" \
    --arg next_steps "Fix the PromQL error or check Prometheus logs. Response snippet: $(echo "$resp" | head -c 400)" \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

mapfile -t rows < <(echo "$resp" | jq -c '.data.result[]?')

if [[ ${#rows[@]} -eq 0 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No \`pgbouncer_up\` Series Found" \
    --arg details "Query returned zero time series. Exporter may be undiscovered, labels may not match PGBOUNCER_JOB_LABEL/METRIC_NAMESPACE_FILTER, or metrics prefix may differ." \
    --arg severity "3" \
    --arg next_steps "Confirm ServiceMonitor targets, job labels, and that prometheus-community/pgbouncer_exporter is scraped. Inspect raw /metrics if metric names differ." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
else
  for row in "${rows[@]}"; do
    val=$(echo "$row" | jq -r '.value[1] // "NaN"')
    pod=$(echo "$row" | jq -r '.metric.pod // .metric.kubernetes_pod_name // "unknown"')
    job=$(echo "$row" | jq -r '.metric.job // "unknown"')
    if awk "BEGIN { exit !($val < 1.0) }"; then
      issues_json=$(echo "$issues_json" | jq \
        --arg title "PgBouncer Exporter Down or Unhealthy (\`pod=${pod}\`, \`job=${job}\`)" \
        --arg details "pgbouncer_up=${val}. Scrape succeeded but PgBouncer or exporter reports unhealthy." \
        --arg severity "4" \
        --arg next_steps "Check PgBouncer process, exporter logs, credentials to pgbouncer admin DB, and network from exporter to PgBouncer." \
        '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    fi
  done
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Results written to $OUTPUT_FILE"
jq . "$OUTPUT_FILE"
