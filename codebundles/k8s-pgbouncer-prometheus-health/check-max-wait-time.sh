#!/usr/bin/env bash
set -euo pipefail
set -x
# Evaluates pgbouncer_pools_client_maxwait_seconds against threshold.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/prom-common.sh"

: "${PROMETHEUS_URL:?}"
: "${PGBOUNCER_JOB_LABEL:?}"

OUTPUT_FILE="max_wait_time_analysis.json"
issues_json='[]'
MAXW="${MAX_WAIT_SECONDS_THRESHOLD:-1}"

INNER="$(prom_label_inner)"
Q="max by (pod, database, user) (pgbouncer_pools_client_maxwait_seconds{${INNER}})"

echo "Checking max client wait time (threshold ${MAXW}s)"

if ! resp="$(prom_instant_query "$Q")"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus Query Failed for Max Wait Time" \
    --arg details "curl error" \
    --arg severity "4" \
    --arg next_steps "Verify Prometheus connectivity." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

if ! prom_check_api "$resp"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus API Error (max wait)" \
    --arg details "$(echo "$resp" | head -c 400)" \
    --arg severity "3" \
    --arg next_steps "Confirm metric name pgbouncer_pools_client_maxwait_seconds exists on your exporter version." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

mapfile -t rows < <(echo "$resp" | jq -c '.data.result[]?')
for row in "${rows[@]}"; do
  val=$(echo "$row" | jq -r '.value[1] // "0"')
  pod=$(echo "$row" | jq -r '.metric.pod // "unknown"')
  db=$(echo "$row" | jq -r '.metric.database // "unknown"')
  usr=$(echo "$row" | jq -r '.metric.user // "unknown"')
  if awk -v v="$val" -v t="$MAXW" 'BEGIN { exit !(v+0 > t+0) }'; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "High PgBouncer Client Max Wait (\`pod=${pod}\`, \`db=${db}\`, \`user=${usr}\`)" \
      --arg details "pgbouncer_pools_client_maxwait_seconds=${val}s (threshold ${MAXW}s)." \
      --arg severity "3" \
      --arg next_steps "Investigate pool saturation, slow queries on PostgreSQL, or mis-sized pools for this database/user." \
      '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  fi
done

echo "$issues_json" > "$OUTPUT_FILE"
jq . "$OUTPUT_FILE"
