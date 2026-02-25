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
OUTPUT_FORMAT="${OUTPUT_FORMAT:-table}"
CSV_FILE="aws_cost_report.csv"
JSON_FILE="aws_cost_report.json"
COST_BUDGET="${COST_BUDGET:-0}"
COST_CONCENTRATION_THRESHOLD="${COST_CONCENTRATION_THRESHOLD:-25}"
TEMP_DIR="${CODEBUNDLE_TEMP_DIR:-.}"

# Cost Explorer is a global service; always use us-east-1 regardless of AWS_REGION
CE_REGION="us-east-1"

echo '[]' > "$ISSUES_FILE"

log() {
    echo "[$(date '+%H:%M:%S')] $*" >&2
}

add_issue() {
    local title="$1" details="$2" severity="$3" next_step="$4"
    local tmp=$(mktemp "$TEMP_DIR/issue_XXXXXX.json")
    jq --arg t "$title" --arg d "$details" --argjson s "$severity" --arg n "$next_step" \
        '. + [{title: $t, details: $d, severity: $s, next_step: $n}]' "$ISSUES_FILE" > "$tmp"
    mv "$tmp" "$ISSUES_FILE"
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
    --region "$CE_REGION" \
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

# Query daily costs for last 7 days
log "Querying daily costs for last 7 days..."
seven_days_ago=$(date -u -d "7 days ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-7d +"%Y-%m-%d" 2>/dev/null)
daily_costs=$(aws ce get-cost-and-usage \
    --region "$CE_REGION" \
    --time-period "Start=$seven_days_ago,End=$end_date" \
    --granularity DAILY \
    --metrics "UnblendedCost" \
    --output json 2>/dev/null || echo '{"ResultsByTime":[]}')

# Query previous period cost by service
log "Querying Cost Explorer for previous period..."
previous_by_service=$(aws ce get-cost-and-usage \
    --region "$CE_REGION" \
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
    --region "$CE_REGION" \
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
high_cost_services=$(echo "$current_services" | jq --argjson total "$current_total" --argjson threshold "$COST_CONCENTRATION_THRESHOLD" 'if $total > 0 then [.[] | select((.cost / $total * 100) > $threshold)] | length else 0 end')
services_under_1=$(echo "$current_services" | jq '[.[] | select(.cost < 1)] | length')

{
cat << EOF
======================================================================
  AWS COST REPORT - LAST ${COST_ANALYSIS_LOOKBACK_DAYS} DAYS
  Account: $ACCOUNT_DISPLAY ($ACCOUNT_ID)
  Period:  $start_date to $end_date
======================================================================

COST SUMMARY
----------------------------------------------------------------------

  Total Cost (Current Period):    \$$current_total
  Total Cost (Previous Period):   \$$previous_total
  Services With Charges:          $service_count
  Services Over \$100:            $services_over_100
  High Cost Contributors (>${COST_CONCENTRATION_THRESHOLD}%):  $high_cost_services
  Services Under \$1:             $services_under_1

----------------------------------------------------------------------

COST TREND ANALYSIS (vs Previous ${COST_ANALYSIS_LOOKBACK_DAYS} Days)
----------------------------------------------------------------------

  Current Period:  $start_date to $end_date = \$$current_total
  Previous Period: $prev_start_date to $prev_end_date = \$$previous_total

  Trend:   $trend_text
  Change:  \$$cost_change_abs (${percent_change}%)
EOF
} > "$REPORT_FILE"

if (( $(echo "$percent_change >= $COST_INCREASE_THRESHOLD" | bc -l 2>/dev/null || echo "0") )); then
    echo "  ALERT:  Cost increase exceeds ${COST_INCREASE_THRESHOLD}% threshold" >> "$REPORT_FILE"
elif (( $(echo "$percent_change > 0" | bc -l 2>/dev/null || echo "0") )); then
    echo "  Status: Within acceptable variance (<${COST_INCREASE_THRESHOLD}%)" >> "$REPORT_FILE"
elif (( $(echo "$percent_change < 0" | bc -l 2>/dev/null || echo "0") )); then
    echo "  Status: Cost decreased" >> "$REPORT_FILE"
else
    echo "  Status: Cost remained stable" >> "$REPORT_FILE"
fi

# Daily spend analysis
{
cat << 'DAILY_HEADER'

----------------------------------------------------------------------

DAILY SPEND (LAST 7 DAYS)
----------------------------------------------------------------------

DAILY_HEADER
} >> "$REPORT_FILE"

daily_entries=$(echo "$daily_costs" | jq -r '
    [.ResultsByTime[] | {
        date: .TimePeriod.Start,
        cost: (.Total.UnblendedCost.Amount // "0" | tonumber)
    }]')

daily_count=$(echo "$daily_entries" | jq 'length')

if [[ "$daily_count" -gt 0 ]]; then
    echo "$daily_entries" | jq -r '.[] | "  " + .date + "  $" + ((.cost * 100 | round) / 100 | tostring)' >> "$REPORT_FILE"
    daily_avg=$(echo "$daily_entries" | jq '[.[].cost] | if length > 0 then add / length | (. * 100 | round) / 100 else 0 end')
    echo "" >> "$REPORT_FILE"
    echo "  7-Day Average: \$$daily_avg/day" >> "$REPORT_FILE"
else
    echo "  No daily cost data available." >> "$REPORT_FILE"
    daily_avg="0"
fi

# Anomaly detection
{
cat << 'ANOMALY_HEADER'

----------------------------------------------------------------------

ANOMALY DETECTION
----------------------------------------------------------------------

ANOMALY_HEADER
} >> "$REPORT_FILE"

if [[ "$daily_count" -gt 0 ]] && (( $(echo "$daily_avg > 0" | bc -l 2>/dev/null || echo "0") )); then
    anomaly_threshold=$(echo "scale=2; $daily_avg * 2" | bc -l 2>/dev/null || echo "0")
    [[ "$anomaly_threshold" == .* ]] && anomaly_threshold="0$anomaly_threshold"
    anomalies=$(echo "$daily_entries" | jq --argjson threshold "$anomaly_threshold" '[.[] | select(.cost > $threshold)]')
    anomaly_count=$(echo "$anomalies" | jq 'length')

    if [[ "$anomaly_count" -gt 0 ]]; then
        echo "  Cost spike detected (threshold: >\$${anomaly_threshold}/day = 2x avg)" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
        echo "$anomalies" | jq -r '.[] | "  SPIKE: " + .date + "  $" + ((.cost * 100 | round) / 100 | tostring)' >> "$REPORT_FILE"

        anomaly_details=$(echo "$anomalies" | jq -r '[.[] | .date + ": $" + ((.cost * 100 | round) / 100 | tostring)] | join(", ")')
        add_issue \
            "AWS Daily Cost Spike Detected for Account ${ACCOUNT_DISPLAY}" \
            "Cost anomaly detected: daily spend exceeded 2x the 7-day average (\$$daily_avg/day).\nAnomaly threshold: \$$anomaly_threshold/day\nSpike days: ${anomaly_details}\n\nAccount: ${ACCOUNT_DISPLAY} (${ACCOUNT_ID})" \
            3 \
            "Review AWS Cost Explorer for the spike dates to identify which services caused the increase.\nCheck for any new resources launched or scaling events.\nVerify no unauthorized usage occurred.\nConsider setting up AWS Budgets with daily alerts."
    else
        echo "  No anomalies detected. Daily spend within normal range." >> "$REPORT_FILE"
        echo "  (Threshold: >\$${anomaly_threshold}/day = 2x average)" >> "$REPORT_FILE"
    fi
else
    echo "  Insufficient daily data for anomaly detection." >> "$REPORT_FILE"
fi

# Budget threshold check
if (( $(echo "$COST_BUDGET > 0" | bc -l 2>/dev/null || echo "0") )); then
    if (( $(echo "$current_total > $COST_BUDGET" | bc -l 2>/dev/null || echo "0") )); then
        budget_overage=$(echo "scale=2; $current_total - $COST_BUDGET" | bc -l 2>/dev/null || echo "0")
        add_issue \
            "AWS Cost Budget Exceeded: \$${current_total} spent vs \$${COST_BUDGET} budget for Account ${ACCOUNT_DISPLAY}" \
            "AWS cost budget exceeded.\n\nAccount: ${ACCOUNT_DISPLAY} (${ACCOUNT_ID})\nBudget: \$$COST_BUDGET\nActual Spend: \$$current_total\nPeriod: $start_date to $end_date\nOver Budget By: \$$budget_overage" \
            3 \
            "Review the cost report for high-spend services.\nIdentify opportunities for cost optimization.\nConsider adjusting the budget or implementing cost controls.\nReview AWS Trusted Advisor recommendations."
    fi
fi

# Cost concentration check
if (( $(echo "$current_total > 0" | bc -l 2>/dev/null || echo "0") )); then
    concentrated_services=$(echo "$current_services" | jq --argjson total "$current_total" --argjson threshold "$COST_CONCENTRATION_THRESHOLD" '
        [.[] | select((.cost / $total * 100) > $threshold) | {service: .service, cost: .cost, percent: ((.cost / $total * 100) | floor)}]
    ')
    concentrated_count=$(echo "$concentrated_services" | jq 'length')

    if [[ "$concentrated_count" -gt 0 ]]; then
        concentration_details=$(echo "$concentrated_services" | jq -r '[.[] | .service + " (" + (.percent | tostring) + "% = $" + ((.cost * 100 | round) / 100 | tostring) + ")"] | join(", ")')
        add_issue \
            "AWS Cost Concentration: Service exceeds ${COST_CONCENTRATION_THRESHOLD}% of total for Account ${ACCOUNT_DISPLAY}" \
            "High cost concentration detected. The following services exceed ${COST_CONCENTRATION_THRESHOLD}% of total spend:\n${concentration_details}\n\nAccount: ${ACCOUNT_DISPLAY} (${ACCOUNT_ID})\nTotal Spend: \$$current_total\nPeriod: $start_date to $end_date" \
            3 \
            "Review the concentrated service(s) for optimization opportunities.\nConsider Reserved Instances or Savings Plans for dominant services.\nEvaluate architectural changes to reduce dependency on high-cost services.\nCheck for over-provisioned resources in the dominant service."
    fi
fi

# Account breakdown (if multi-account)
account_count=$(echo "$account_breakdown" | jq 'length' 2>/dev/null || echo "0")
if [[ "$account_count" -gt 1 ]]; then
    {
    cat << EOF

----------------------------------------------------------------------

COST BY LINKED ACCOUNT
----------------------------------------------------------------------

EOF
    } >> "$REPORT_FILE"
    echo "$account_breakdown" | jq -r --argjson total "$current_total" '
        .[] |
        "  " + .account +
        ": $" + ((.cost * 100 | round) / 100 | tostring) +
        " (" + (if $total > 0 then ((.cost / $total * 100) | floor | tostring) else "0" end) + "%)"
    ' >> "$REPORT_FILE"
fi

# Top services
{
cat << EOF

======================================================================

TOP SERVICES BY COST
======================================================================

  SERVICE                                          COST        %
----------------------------------------------------------------------

EOF
} >> "$REPORT_FILE"

echo "$current_services" | jq -r --argjson total "$current_total" --argjson threshold "$COST_CONCENTRATION_THRESHOLD" '
    .[:20] |
    .[] |
    "  " +
    (.service | if length > 45 then .[:42] + "..." else . + (" " * (45 - length)) end) +
    "  $" +
    ((.cost * 100 | round) / 100 | tostring |
     if length < 10 then (" " * (10 - length)) + . else . end) +
    "  (" +
    (if $total > 0 then ((.cost / $total * 100) | floor | tostring) else "0" end) +
    "%)" +
    (if $total > 0 then (if (.cost / $total * 100) > $threshold then " \u26a0\ufe0f" else "" end) else "" end)
' >> "$REPORT_FILE"

# Service-level comparison (top movers)
{
cat << EOF

======================================================================

TOP COST CHANGES BY SERVICE (vs Previous Period)
======================================================================

  SERVICE                                   CURRENT    PREVIOUS   CHANGE
----------------------------------------------------------------------

EOF
} >> "$REPORT_FILE"

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
    sort_by(-(.change | abs)) |
    .[:15] |
    .[] |
    "  " +
    (.service | if length > 38 then .[:35] + "..." else . + (" " * (38 - length)) end) +
    "  $" + ((.current * 100 | round) / 100 | tostring | if length < 8 then (" " * (8 - length)) + . else . end) +
    "  $" + ((.previous * 100 | round) / 100 | tostring | if length < 8 then (" " * (8 - length)) + . else . end) +
    (if .change >= 0 then "  +$" else "  -$" end) +
    ((.change | abs * 100 | round) / 100 | tostring)
' >> "$REPORT_FILE"

{
cat << EOF

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
} >> "$REPORT_FILE"

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

    add_issue \
        "AWS Cost Increase: ${percent_change}% (\$${cost_change_abs} increase over ${COST_ANALYSIS_LOOKBACK_DAYS} days) for Account ${ACCOUNT_DISPLAY}" \
        "AWS COST TREND ALERT\n\nAccount: ${ACCOUNT_DISPLAY} (${ACCOUNT_ID})\nCurrent Period ($start_date to $end_date): \$$current_total\nPrevious Period ($prev_start_date to $prev_end_date): \$$previous_total\nChange: \$$cost_change_abs (${percent_change}%)\nThreshold: ${COST_INCREASE_THRESHOLD}%\n\nTop Cost Increases:\n${top_movers}" \
        "$severity" \
        "Review the detailed cost report for service-level breakdowns.\nCheck AWS Cost Explorer in the console for granular analysis.\nLook for new or scaled-up services, unexpected data transfer charges, or runaway workloads.\nReview AWS Trusted Advisor for optimization recommendations.\nConsider Reserved Instances or Savings Plans for predictable workloads.\nSet up AWS Budgets for proactive cost monitoring."
fi

# CSV export
if [[ "$OUTPUT_FORMAT" == "csv" || "$OUTPUT_FORMAT" == "all" ]]; then
    log "Generating CSV export..."
    echo "Service,CurrentCost,PreviousCost,Change,ChangePercent" > "$CSV_FILE"
    echo "$current_services" | jq -r --argjson prev "$previous_services" '
        ($prev | map({(.service): .cost}) | add // {}) as $prev_map |
        .[] |
        {
            service: .service,
            current: ((.cost * 100 | round) / 100),
            previous: ((($prev_map[.service] // 0) * 100 | round) / 100),
            change: (((.cost - ($prev_map[.service] // 0)) * 100 | round) / 100),
            change_pct: (if ($prev_map[.service] // 0) > 0 then
                (((.cost - ($prev_map[.service] // 0)) / ($prev_map[.service] // 1) * 100) | floor | tostring)
            else "N/A" end)
        } |
        .service + "," + (.current | tostring) + "," + (.previous | tostring) + "," + (.change | tostring) + "," + .change_pct
    ' >> "$CSV_FILE"
    log "CSV report written to $CSV_FILE"
fi

# JSON export
if [[ "$OUTPUT_FORMAT" == "json" || "$OUTPUT_FORMAT" == "all" ]]; then
    log "Generating JSON export..."
    echo "$current_services" | jq --argjson prev "$previous_services" \
        --arg start "$start_date" --arg end "$end_date" \
        --arg account_id "$ACCOUNT_ID" --arg account_alias "$ACCOUNT_ALIAS" \
        --argjson total "$current_total" --argjson prev_total "$previous_total" \
        --arg pct_change "$percent_change" '
        ($prev | map({(.service): .cost}) | add // {}) as $prev_map |
        {
            reportPeriod: {startDate: $start, endDate: $end},
            account: {id: $account_id, alias: $account_alias},
            totalCost: $total,
            previousPeriodCost: $prev_total,
            percentChange: ($pct_change | tonumber),
            currency: "USD",
            services: [.[] | {
                serviceName: .service,
                cost: ((.cost * 100 | round) / 100),
                previousCost: ((($prev_map[.service] // 0) * 100 | round) / 100),
                change: (((.cost - ($prev_map[.service] // 0)) * 100 | round) / 100)
            }]
        }
    ' > "$JSON_FILE"
    log "JSON report written to $JSON_FILE"
fi

log "Cost report generation complete."
