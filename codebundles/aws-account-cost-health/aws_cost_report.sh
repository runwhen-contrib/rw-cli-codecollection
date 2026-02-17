#!/bin/bash

# AWS Account Cost Report
# Generates a detailed cost breakdown using AWS Cost Explorer API
# with period-over-period trend analysis and threshold-based alerting.

source "$(dirname "$0")/auth.sh"
auth

# Environment Variables
COST_ANALYSIS_LOOKBACK_DAYS="${COST_ANALYSIS_LOOKBACK_DAYS:-30}"
COST_INCREASE_THRESHOLD="${COST_INCREASE_THRESHOLD:-10}"
REPORT_FILE="aws_cost_report.txt"
ISSUES_FILE="aws_cost_trend_issues.json"

echo '[]' > "$ISSUES_FILE"

log() {
    echo "[$(date '+%H:%M:%S')] $*" >&2
}

# Date calculations
end_date=$(date -u +"%Y-%m-%d")
start_date=$(date -u -d "${COST_ANALYSIS_LOOKBACK_DAYS} days ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-${COST_ANALYSIS_LOOKBACK_DAYS}d +"%Y-%m-%d" 2>/dev/null)
prev_end_date="$start_date"
prev_start_date=$(date -u -d "$((COST_ANALYSIS_LOOKBACK_DAYS * 2)) days ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-$((COST_ANALYSIS_LOOKBACK_DAYS * 2))d +"%Y-%m-%d" 2>/dev/null)

log "Starting AWS cost report generation"
log "Current period:  $start_date to $end_date"
log "Previous period: $prev_start_date to $prev_end_date"

# Get account ID and alias for display
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null || echo "unknown")
ACCOUNT_ALIAS=$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null || echo "")
ACCOUNT_DISPLAY="${ACCOUNT_ALIAS:-$ACCOUNT_ID}"

# Query current period cost by service
log "Querying Cost Explorer for current period..."
current_by_service=$(aws ce get-cost-and-usage \
    --time-period "Start=$start_date,End=$end_date" \
    --granularity MONTHLY \
    --metrics "UnblendedCost" \
    --group-by Type=DIMENSION,Key=SERVICE \
    --output json 2>&1)

if [[ $? -ne 0 ]]; then
    echo "Error: Failed to query AWS Cost Explorer"
    echo "$current_by_service"
    jq -n '[{
        "title": "Failed to Query AWS Cost Explorer",
        "details": "aws ce get-cost-and-usage returned an error. Ensure the IAM role has ce:GetCostAndUsage permission and Cost Explorer is enabled.",
        "severity": 2,
        "next_step": "Enable Cost Explorer in the AWS Billing console if not already enabled.\nVerify IAM permissions include ce:GetCostAndUsage.\nCheck that the AWS account has billing access enabled."
    }]' > "$ISSUES_FILE"
    exit 0
fi

# Aggregate current period costs by service
current_services=$(echo "$current_by_service" | jq -r '
    [.ResultsByTime[].Groups[] |
        {
            service: .Keys[0],
            cost: (.Metrics.UnblendedCost.Amount | tonumber)
        }
    ] |
    group_by(.service) |
    map({
        service: .[0].service,
        cost: (map(.cost) | add)
    }) |
    sort_by(-.cost)
')

current_total=$(echo "$current_services" | jq '[.[].cost] | add // 0 | (. * 100 | round) / 100')

log "Current period total: \$$current_total"

# Query previous period cost by service
log "Querying Cost Explorer for previous period..."
previous_by_service=$(aws ce get-cost-and-usage \
    --time-period "Start=$prev_start_date,End=$prev_end_date" \
    --granularity MONTHLY \
    --metrics "UnblendedCost" \
    --group-by Type=DIMENSION,Key=SERVICE \
    --output json 2>&1)

previous_total=0
previous_services='[]'
if [[ $? -eq 0 ]]; then
    previous_services=$(echo "$previous_by_service" | jq -r '
        [.ResultsByTime[].Groups[] |
            {
                service: .Keys[0],
                cost: (.Metrics.UnblendedCost.Amount | tonumber)
            }
        ] |
        group_by(.service) |
        map({
            service: .[0].service,
            cost: (map(.cost) | add)
        }) |
        sort_by(-.cost)
    ')
    previous_total=$(echo "$previous_services" | jq '[.[].cost] | add // 0 | (. * 100 | round) / 100')
fi

log "Previous period total: \$$previous_total"

# Query current period cost by linked account (for multi-account/org)
log "Querying costs by linked account..."
current_by_account=$(aws ce get-cost-and-usage \
    --time-period "Start=$start_date,End=$end_date" \
    --granularity MONTHLY \
    --metrics "UnblendedCost" \
    --group-by Type=DIMENSION,Key=LINKED_ACCOUNT \
    --output json 2>/dev/null)

account_breakdown=""
if [[ $? -eq 0 ]]; then
    account_breakdown=$(echo "$current_by_account" | jq -r '
        [.ResultsByTime[].Groups[] |
            {
                account: .Keys[0],
                cost: (.Metrics.UnblendedCost.Amount | tonumber)
            }
        ] |
        group_by(.account) |
        map({
            account: .[0].account,
            cost: (map(.cost) | add)
        }) |
        sort_by(-.cost)
    ')
fi

# Calculate trend
cost_change=$(echo "scale=2; $current_total - $previous_total" | bc -l 2>/dev/null || echo "0")
cost_change_abs=$(echo "$cost_change" | tr -d '-')

percent_change="0"
if (( $(echo "$previous_total > 0" | bc -l 2>/dev/null || echo "0") )); then
    percent_change=$(echo "scale=2; ($cost_change / $previous_total) * 100" | bc -l 2>/dev/null || echo "0")
fi

percent_change_abs=$(echo "$percent_change" | tr -d '-')

if (( $(echo "$percent_change > 0" | bc -l 2>/dev/null || echo "0") )); then
    trend_text="INCREASING"
elif (( $(echo "$percent_change < 0" | bc -l 2>/dev/null || echo "0") )); then
    trend_text="DECREASING"
else
    trend_text="STABLE"
fi

# Generate report
service_count=$(echo "$current_services" | jq 'length')
services_over_100=$(echo "$current_services" | jq '[.[] | select(.cost > 100)] | length')

cat > "$REPORT_FILE" << EOF
======================================================================
  AWS COST REPORT - LAST ${COST_ANALYSIS_LOOKBACK_DAYS} DAYS
  Account: $ACCOUNT_DISPLAY ($ACCOUNT_ID)
  Period:  $start_date to $end_date
======================================================================

COST SUMMARY
----------------------------------------------------------------------

  Total Cost (Current Period):   \$$current_total
  Total Cost (Previous Period):  \$$previous_total
  Services With Charges:         $service_count
  Services Over \$100:           $services_over_100

----------------------------------------------------------------------

COST TREND ANALYSIS (vs Previous ${COST_ANALYSIS_LOOKBACK_DAYS} Days)
----------------------------------------------------------------------

  Current Period:  $start_date to $end_date = \$$current_total
  Previous Period: $prev_start_date to $prev_end_date = \$$previous_total

  Trend:   $trend_text
  Change:  \$$cost_change_abs (${percent_change}%)
EOF

if (( $(echo "$percent_change >= $COST_INCREASE_THRESHOLD" | bc -l 2>/dev/null || echo "0") )); then
    echo "  ALERT:  Cost increase exceeds ${COST_INCREASE_THRESHOLD}% threshold" >> "$REPORT_FILE"
elif (( $(echo "$percent_change > 0" | bc -l 2>/dev/null || echo "0") )); then
    echo "  Status: Within acceptable variance (<${COST_INCREASE_THRESHOLD}%)" >> "$REPORT_FILE"
elif (( $(echo "$percent_change < 0" | bc -l 2>/dev/null || echo "0") )); then
    echo "  Status: Cost decreased" >> "$REPORT_FILE"
else
    echo "  Status: Cost remained stable" >> "$REPORT_FILE"
fi

# Account breakdown (if multi-account)
account_count=$(echo "$account_breakdown" | jq 'length' 2>/dev/null || echo "0")
if [[ "$account_count" -gt 1 ]]; then
    cat >> "$REPORT_FILE" << EOF

----------------------------------------------------------------------

COST BY LINKED ACCOUNT
----------------------------------------------------------------------

EOF
    echo "$account_breakdown" | jq -r --argjson total "$current_total" '
        .[] |
        "  " + .account +
        ": $" + ((.cost * 100 | round) / 100 | tostring) +
        " (" + (if $total > 0 then ((.cost / $total * 100) | floor | tostring) else "0" end) + "%)"
    ' >> "$REPORT_FILE"
fi

# Top services
cat >> "$REPORT_FILE" << EOF

======================================================================

TOP SERVICES BY COST
======================================================================

  SERVICE                                          COST        %
----------------------------------------------------------------------

EOF

echo "$current_services" | jq -r --argjson total "$current_total" '
    .[:20] |
    .[] |
    "  " +
    (.service | if length > 45 then .[:42] + "..." else . + (" " * (45 - length)) end) +
    "  $" +
    ((.cost * 100 | round) / 100 | tostring |
     if length < 10 then (" " * (10 - length)) + . else . end) +
    "  (" +
    (if $total > 0 then ((.cost / $total * 100) | floor | tostring) else "0" end) +
    "%)"
' >> "$REPORT_FILE"

# Service-level comparison (top movers)
cat >> "$REPORT_FILE" << EOF

======================================================================

TOP COST CHANGES BY SERVICE (vs Previous Period)
======================================================================

  SERVICE                                   CURRENT    PREVIOUS   CHANGE
----------------------------------------------------------------------

EOF

# Merge current and previous by service for comparison
echo "$current_services" | jq -r --argjson prev "$previous_services" '
    . as $curr |
    ($prev | map({(.service): .cost}) | add // {}) as $prev_map |
    [.[] | {
        service: .service,
        current: .cost,
        previous: ($prev_map[.service] // 0),
        change: (.cost - ($prev_map[.service] // 0))
    }] |
    sort_by(-.change | fabs) |
    .[:15] |
    .[] |
    "  " +
    (.service | if length > 38 then .[:35] + "..." else . + (" " * (38 - length)) end) +
    "  $" + ((.current * 100 | round) / 100 | tostring | if length < 8 then (" " * (8 - length)) + . else . end) +
    "  $" + ((.previous * 100 | round) / 100 | tostring | if length < 8 then (" " * (8 - length)) + . else . end) +
    (if .change >= 0 then "  +$" else "  -$" end) +
    ((.change | fabs * 100 | round) / 100 | tostring)
' >> "$REPORT_FILE"

cat >> "$REPORT_FILE" << EOF

======================================================================

COST OPTIMIZATION TIPS:
  - Review AWS Trusted Advisor for cost optimization recommendations
  - Check for unused EC2 instances, EBS volumes, and Elastic IPs
  - Consider Reserved Instances or Savings Plans for steady-state workloads
  - Enable S3 Intelligent-Tiering for infrequently accessed data
  - Review and rightsize oversized RDS instances
  - Clean up unused NAT Gateways and idle Load Balancers

======================================================================
EOF

# Print report
cat "$REPORT_FILE"

# Generate issue if cost increased beyond threshold
if (( $(echo "$percent_change >= $COST_INCREASE_THRESHOLD" | bc -l 2>/dev/null || echo "0") )); then
    severity=3
    if (( $(echo "$percent_change >= 25" | bc -l 2>/dev/null || echo "0") )); then
        severity=2
    fi

    top_movers=$(echo "$current_services" | jq -r --argjson prev "$previous_services" '
        . as $curr |
        ($prev | map({(.service): .cost}) | add // {}) as $prev_map |
        [.[] | {
            service: .service,
            current: .cost,
            previous: ($prev_map[.service] // 0),
            change: (.cost - ($prev_map[.service] // 0))
        }] |
        sort_by(-.change) |
        .[:5] |
        .[] |
        "  - " + .service + ": +$" + ((.change * 100 | round) / 100 | tostring)
    ')

    jq -n \
        --arg title "AWS Cost Increase: ${percent_change}% (\$${cost_change_abs} increase over ${COST_ANALYSIS_LOOKBACK_DAYS} days) for Account ${ACCOUNT_DISPLAY}" \
        --arg details "AWS COST TREND ALERT\n\nAccount: ${ACCOUNT_DISPLAY} (${ACCOUNT_ID})\nCurrent Period ($start_date to $end_date): \$$current_total\nPrevious Period ($prev_start_date to $prev_end_date): \$$previous_total\nChange: \$$cost_change_abs (${percent_change}%)\nThreshold: ${COST_INCREASE_THRESHOLD}%\n\nTop Cost Increases:\n${top_movers}" \
        --arg next_step "Review the detailed cost report for service-level breakdowns.\nCheck AWS Cost Explorer in the console for granular analysis.\nLook for new or scaled-up services, unexpected data transfer charges, or runaway workloads.\nReview AWS Trusted Advisor for optimization recommendations.\nConsider Reserved Instances or Savings Plans for predictable workloads.\nSet up AWS Budgets for proactive cost monitoring." \
        --argjson severity "$severity" \
        '[{title: $title, details: $details, severity: $severity, next_step: $next_step}]' \
        > "$ISSUES_FILE"
fi

log "Cost report generation complete."
