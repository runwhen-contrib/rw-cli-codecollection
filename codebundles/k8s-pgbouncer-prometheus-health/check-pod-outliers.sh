#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prometheus-common.sh
source "${SCRIPT_DIR}/lib/prometheus-common.sh"

: "${PROMETHEUS_URL:?Must set PROMETHEUS_URL}"
: "${PGBOUNCER_JOB_LABEL:?Must set PGBOUNCER_JOB_LABEL}"

OUTPUT_FILE="check_pod_outliers_output.json"
RATIO="${POD_OUTLIER_RATIO:-2.0}"

wm=$(wrap_metric pgbouncer_pools_client_active_connections)
q="sum by (pod) (${wm})"
echo "Instant query: $q"

raw=$(prometheus_instant_query "$q" || true)
if ! prometheus_query_status_ok "${raw:-}" 2>/dev/null; then
  echo '[]' | jq \
    --arg title "Prometheus Error for Pod Outlier Detection" \
    --arg details "Could not query per-pod client active connections." \
    --arg severity "3" \
    --arg next_steps "Verify Prometheus and that pod label exists on pool metrics." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]' > "$OUTPUT_FILE"
  exit 0
fi

issues_json=$(echo "$raw" | jq -c --argjson ratio "$RATIO" '
  .data.result as $r |
  if ($r | length) == 0 then []
  else
    ($r | map(.value[1] | tonumber)) as $vals |
    (($vals | add) / ($vals | length)) as $mean |
    if ($mean == 0) then []
    else
      $r | map(
        (.value[1] | tonumber) as $v |
        (.metric.pod // .metric.kubernetes_pod_name // "unknown") as $pod |
        select($v > ($mean * $ratio)) |
        {
          title: ("PgBouncer Pod Outlier: `" + $pod + "`"),
          details: ("Pod has client_active sum " + ($v|tostring) + " vs fleet mean " + ($mean|tostring) + " (ratio threshold " + ($ratio|tostring) + "x)."),
          severity: 3,
          next_steps: "Investigate this replica for skewed traffic, local saturation, or failing readiness; verify Service sessionAffinity and endpoints."
        }
      )
    end
  end
')

echo "$issues_json" > "$OUTPUT_FILE"
jq '.' "$OUTPUT_FILE"
