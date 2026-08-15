#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Generate Load Balancer Health Summary
#
# Aggregates findings from all previous checks into a consolidated health
# summary table showing each load balancer, its type, SSL status, backend
# status, error rate, latency, and an overall health verdict.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID    - GCP project ID hosting the load balancers
#
# INPUTS (files written by sibling check scripts):
#   lb_config.json                 - discovered load balancers
#   ssl_certificate_issues.json    - SSL issues
#   backend_health_issues.json     - backend issues
#   error_rate_issues.json         - error rate issues
#   latency_issues.json            - latency issues
#
# OUTPUTS:
#   lb_summary_issues.json - JSON array of issues (informational summary)
#   lb_summary_table.txt   - Human readable summary table
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

ISSUES_FILE="lb_summary_issues.json"
TABLE_FILE="lb_summary_table.txt"

echo "Generating load balancer health summary for project: $GCP_PROJECT_ID"

if [ ! -f "lb_config.json" ]; then
    echo "No discovery data found (lb_config.json missing). Run the discovery task first."
    echo "[]" > "$ISSUES_FILE"
    echo "No load balancer configuration discovered." > "$TABLE_FILE"
    exit 0
fi

lb_count=$(jq 'length' lb_config.json)
if [ "$lb_count" -eq 0 ]; then
    echo "No load balancers discovered in project $GCP_PROJECT_ID."
    echo "[]" > "$ISSUES_FILE"
    echo "No load balancers discovered in project $GCP_PROJECT_ID." > "$TABLE_FILE"
    exit 0
fi

# Count issues per dimension that reference each load balancer.
count_issues_for_lb() {
    local file="$1"
    local lb_name="$2"
    if [ -f "$file" ]; then
        jq --arg n "$lb_name" '[.[] | select(.title | contains($n))] | length' "$file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

total_issues=0
> "$TABLE_FILE"
printf '%-32s %-8s %-10s %-8s %-10s %-8s %s\n' "LOAD BALANCER" "TYPE" "SSL" "BACKEND" "ERROR_RATE" "LATENCY" "VERDICT" >> "$TABLE_FILE"
printf '%s\n' "------------------------------------------------------------------------" >> "$TABLE_FILE"

jq -c '.[]' lb_config.json | while read -r lb; do
    name=$(echo "$lb" | jq -r '.name')
    type=$(echo "$lb" | jq -r '.type')

    ssl_issues=$(count_issues_for_lb "ssl_certificate_issues.json" "$name")
    backend_issues=$(count_issues_for_lb "backend_health_issues.json" "$name")
    error_issues=$(count_issues_for_lb "error_rate_issues.json" "$name")
    latency_issues=$(count_issues_for_lb "latency_issues.json" "$name")

    # For non-TLS types, SSL is not applicable.
    if [ "$type" = "SSL" ] || [ "$type" = "HTTPS" ]; then
        ssl_ok="OK"
        [ "$ssl_issues" -gt 0 ] && ssl_ok="CHECK"
    else
        ssl_ok="N/A"
    fi

    backend_ok="OK"
    [ "$backend_issues" -gt 0 ] && backend_ok="DEGRADED"
    error_ok="OK"
    [ "$error_issues" -gt 0 ] && error_ok="ELEVATED"
    latency_ok="OK"
    [ "$latency_issues" -gt 0 ] && latency_ok="HIGH"

    verdict="healthy"
    [ "$ssl_ok" = "CHECK" ] && verdict="attention"
    [ "$backend_ok" = "DEGRADED" ] && verdict="degraded"
    [ "$error_ok" = "ELEVATED" ] && verdict="degraded"
    [ "$latency_ok" = "HIGH" ] && verdict="degraded"

    printf '%-32s %-8s %-10s %-8s %-10s %-8s %s\n' "$name" "$type" "$ssl_ok" "$backend_ok" "$error_ok" "$latency_ok" "$verdict" >> "$TABLE_FILE"
done

echo "Summary written to $TABLE_FILE"
cat "$TABLE_FILE"
echo "[]" > "$ISSUES_FILE"
echo "Load balancer health summary generated for $(jq length lb_config.json) load balancer(s)."
