#!/usr/bin/env bash
set -euo pipefail
set -x
# Detects clients waiting while server-side idle headroom exists (misconfiguration signal).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/prom-common.sh"

: "${PROMETHEUS_URL:?}"
: "${PGBOUNCER_JOB_LABEL:?}"

OUTPUT_FILE="server_pool_balance_analysis.json"
issues_json='[]'

INNER="$(prom_label_inner)"
QW="sum by (pod, database, user) (pgbouncer_pools_client_waiting_connections{${INNER}})"
QI="sum by (pod, database, user) (pgbouncer_pools_server_idle_connections{${INNER}})"

echo "Checking server pool balance (waiting vs idle)"

if ! rw="$(prom_instant_query "$QW")" || ! ri="$(prom_instant_query "$QI")"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus Query Failed for Pool Balance" \
    --arg details "curl error" \
    --arg severity "4" \
    --arg next_steps "Verify Prometheus URL." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

if ! prom_check_api "$rw" || ! prom_check_api "$ri"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus API Error (pool balance)" \
    --arg details "One of waiting/idle queries failed" \
    --arg severity "3" \
    --arg next_steps "Confirm pgbouncer_pools_* metrics exist." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

# Build jq map of idle by pod/database/user
idle_map=$(echo "$ri" | jq -c '[.data.result[]? | {key: (.metric.pod // "na") + "|" + (.metric.database // "na") + "|" + (.metric.user // "na"), v: (.value[1] | tonumber)}] | map({(.key): .v}) | add // {}')

while IFS= read -r row; do
  [[ -z "$row" ]] && continue
  w=$(echo "$row" | jq -r '.value[1] // "0"')
  awk -v w="$w" 'BEGIN { exit !(w+0 > 0) }' || continue
  pod=$(echo "$row" | jq -r '.metric.pod // "na"')
  db=$(echo "$row" | jq -r '.metric.database // "na"')
  usr=$(echo "$row" | jq -r '.metric.user // "na"')
  key="${pod}|${db}|${usr}"
  iv=$(echo "$idle_map" | jq -r --arg k "$key" '.[$k] // 0')
  awk -v iv="$iv" 'BEGIN { exit !(iv+0 > 0) }' || continue
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Pool Imbalance: Clients Waiting With Idle Servers (\`pod=${pod}\`, \`db=${db}\`)" \
    --arg details "client_waiting=${w} and server_idle=${iv} for the same pool. Suggests wrong pool_mode, routing, or reservation settings while spare server connections exist." \
    --arg severity "2" \
    --arg next_steps "Review pool_mode, ignore_startup_parameters, user/database routing, and whether reserves or per-db pool_size force waits despite global idle servers." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
done < <(echo "$rw" | jq -c '.data.result[]?')

echo "$issues_json" > "$OUTPUT_FILE"
jq . "$OUTPUT_FILE"
