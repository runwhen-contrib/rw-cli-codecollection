#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prometheus-common.sh
source "${SCRIPT_DIR}/lib/prometheus-common.sh"

: "${PROMETHEUS_URL:?Must set PROMETHEUS_URL}"
: "${PGBOUNCER_JOB_LABEL:?Must set PGBOUNCER_JOB_LABEL}"

OUTPUT_FILE="check_connection_growth_rate_output.json"
WIN_M="${GROWTH_RATE_WINDOW_MINUTES:-15}"
RATE_THR="${CONNECTION_GROWTH_RATE_THRESHOLD:-0.1}"

wm=$(wrap_metric pgbouncer_pools_client_active_connections)
end=$(date +%s)
start=$((end - WIN_M * 60))
step="30s"

q="rate(${wm}[5m])"
echo "Range query: $q from $start to $end"

raw=$(prometheus_range_query "$q" "$start" "$end" "$step" || true)

if ! prometheus_query_status_ok "${raw:-}" 2>/dev/null; then
  echo '[]' | jq \
    --arg title "Prometheus Range Query Failed for Connection Growth" \
    --arg details "Could not evaluate rate() over the lookback window." \
    --arg severity "2" \
    --arg next_steps "Confirm Prometheus supports range queries and that a 5m window has sufficient samples." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]' > "$OUTPUT_FILE"
  exit 0
fi

issues_json=$(echo "$raw" | jq -c --argjson thr "$RATE_THR" '
  .data.result as $r |
  if ($r | length) == 0 then []
  else
    $r | map(
      . as $series |
      ($series.values | map(.[1] | tonumber) | add / length) as $avg |
      select($avg > $thr) |
      ($series.metric.pod // $series.metric.kubernetes_pod_name // "unknown") as $pod |
      {
        title: ("Sustained Client Connection Growth for Pod `" + $pod + "`"),
        details: ("Average rate of client_active_connections over the window is approximately " + ($avg|tostring) + " conn/s (threshold " + ($thr|tostring) + ")."),
        severity: 3,
        next_steps: "Check for connection leaks in apps, pooler misconfiguration, or traffic shifts; compare with deployment rollouts."
      }
    )
  end
')

echo "$issues_json" > "$OUTPUT_FILE"
jq '.' "$OUTPUT_FILE"
