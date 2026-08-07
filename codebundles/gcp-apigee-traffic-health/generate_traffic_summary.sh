#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Generate Apigee Traffic Health Summary
#
# Aggregates error, latency, throughput, and target findings into a
# consolidated traffic health summary (worst proxies by error rate and latency,
# anomaly count, overall verdict).
#
# REQUIRED ENV VARS:
#   APIGEE_ORG         - Apigee organization name
#   GCP_PROJECT_ID     - GCP project hosting the Apigee runtime
#   ERROR_RATE_THRESHOLD   - Error/fault rate threshold in percent (default 5)
#   LATENCY_MS_THRESHOLD   - Latency threshold in ms (default 500)
#
# Reads the per-check report files produced by the other scripts and writes:
#   traffic_summary_table.txt   - Human-readable summary table
#   traffic_summary_issues.json - JSON array of aggregated issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${ERROR_RATE_THRESHOLD:=5}"
: "${LATENCY_MS_THRESHOLD:=500}"

TABLE_FILE="traffic_summary_table.txt"
ISSUES_FILE="traffic_summary_issues.json"
issues_json='[]'

echo "Generating Apigee traffic health summary for org: $APIGEE_ORG (project: $GCP_PROJECT_ID)"

# --- Load per-check reports if present ---
[ -f "error_rate_report.json" ] && ERR_RPT=$(cat error_rate_report.json) || ERR_RPT='[]'
[ -f "latency_report.json" ] && LAT_RPT=$(cat latency_report.json) || LAT_RPT='[]'
[ -f "throughput_report.json" ] && THR_RPT=$(cat throughput_report.json) || THR_RPT='[]'
[ -f "target_report.json" ] && TGT_RPT=$(cat target_report.json) || TGT_RPT='[]'

[ -f "error_rate_issues.json" ] && ERR_ISSUES=$(cat error_rate_issues.json) || ERR_ISSUES='[]'
[ -f "latency_issues.json" ] && LAT_ISSUES=$(cat latency_issues.json) || LAT_ISSUES='[]'
[ -f "throughput_issues.json" ] && THR_ISSUES=$(cat throughput_issues.json) || THR_ISSUES='[]'
[ -f "target_performance_issues.json" ] && TGT_ISSUES=$(cat target_performance_issues.json) || TGT_ISSUES='[]'

err_count=$(echo "$ERR_ISSUES" | jq 'length')
lat_count=$(echo "$LAT_ISSUES" | jq 'length')
thr_count=$(echo "$THR_ISSUES" | jq 'length')
tgt_count=$(echo "$TGT_ISSUES" | jq 'length')
total_count=$(( err_count + lat_count + thr_count + tgt_count ))

anomaly_total=$(echo "$THR_RPT" | jq '[.[].anomaly_count // 0] | add // 0' 2>/dev/null || echo 0)

# --- Worst proxies by error rate and latency ---
worst_err=$(echo "$ERR_RPT" | jq -r 'sort_by(-.error_rate_percent) | .[:5][] | "\(.proxy): \(.error_rate_percent)%"' 2>/dev/null || true)
worst_lat=$(echo "$LAT_RPT" | jq -r 'sort_by(-.p95_ms) | .[:5][] | "\(.proxy): \(.p95_ms)ms"' 2>/dev/null || true)

# --- Overall verdict ---
if [ "$total_count" -eq 0 ]; then
    verdict="HEALTHY"
    overall_sev=1
elif [ "$total_count" -le 2 ]; then
    verdict="DEGRADED"
    overall_sev=2
else
    verdict="UNHEALTHY"
    overall_sev=3
fi

# --- Build table ---
{
    echo "Apigee Traffic Health Summary - Org $APIGEE_ORG / Project $GCP_PROJECT_ID"
    echo "Overall Verdict: $verdict (total findings: $total_count)"
    echo "  Error/fault rate issues: $err_count (threshold ${ERROR_RATE_THRESHOLD}%)"
    echo "  Latency issues: $lat_count (threshold ${LATENCY_MS_THRESHOLD}ms)"
    echo "  Throughput/anomaly issues: $thr_count (total anomalies: $anomaly_total)"
    echo "  Target/backend issues: $tgt_count"
    echo
    echo "Worst proxies by error rate:"
    if [ -n "$worst_err" ]; then echo "$worst_err" | sed 's/^/  /'; else echo "  (none)"; fi
    echo
    echo "Worst proxies by latency:"
    if [ -n "$worst_lat" ]; then echo "$worst_lat" | sed 's/^/  /'; else echo "  (none)"; fi
} > "$TABLE_FILE"

cat "$TABLE_FILE"

# --- Emit an aggregated issue reflecting overall verdict when degraded ---
if [ "$total_count" -gt 0 ]; then
    issue=$(jq -n \
        --arg title "Apigee traffic health is $verdict for org \`$APIGEE_ORG\`" \
        --arg details "Aggregated traffic health for Apigee org '$APIGEE_ORG' (project '$GCP_PROJECT_ID') found $total_count finding(s): $err_count error/fault, $lat_count latency, $thr_count throughput/anomaly, $tgt_count target/backend. Overall verdict: $verdict." \
        --arg severity "$overall_sev" \
        --arg expected "Apigee traffic health should be healthy with no degraded proxies or targets" \
        --arg actual "Apigee traffic health is $verdict with $total_count finding(s)" \
        --arg next_steps "Review the individual error, latency, throughput, and target issues above and take corrective action on affected proxies and target servers." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "$issues_json" | jq --argjson i "$issue" '. += [$i]')
fi

echo "$issues_json" > "$ISSUES_FILE"
echo "Summary complete. Verdict: $verdict ($total_count findings)."
