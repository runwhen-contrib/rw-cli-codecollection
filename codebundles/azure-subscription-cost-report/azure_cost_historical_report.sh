#!/bin/bash

# Azure Cost Report by Service and Resource Group
# Generates a detailed cost breakdown for the last 30 days

# Environment Variables
SUBSCRIPTION_IDS="${AZURE_SUBSCRIPTION_IDS}"
RESOURCE_GROUPS="${AZURE_RESOURCE_GROUPS:-all}"  # comma-separated or "all"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-table}"  # table, csv, json
REPORT_FILE="${REPORT_FILE:-azure_cost_report.txt}"
CSV_FILE="${CSV_FILE:-azure_cost_report.csv}"
JSON_FILE="${JSON_FILE:-azure_cost_report.json}"
ISSUES_FILE="${ISSUES_FILE:-azure_cost_trend_issues.json}"

# Cost trend analysis settings
COST_INCREASE_THRESHOLD="${COST_INCREASE_THRESHOLD:-10}"  # Default: alert on >10% increase
COST_ANALYSIS_LOOKBACK_DAYS="${COST_ANALYSIS_LOOKBACK_DAYS:-30}"  # Default: 30-day periods
COST_BUDGET="${COST_BUDGET:-0}"  # Budget threshold in USD (0 = disabled)
COST_CONCENTRATION_THRESHOLD="${COST_CONCENTRATION_THRESHOLD:-25}"  # Max % of total per resource group

# Temp directory for large data processing (use codebundle temp dir or fallback to current)
TEMP_DIR="${CODEBUNDLE_TEMP_DIR:-.}"

# Logging function
log() {
    echo "💰 [$(date '+%H:%M:%S')] $*" >&2
}

# Get date range for current period
get_date_range() {
    local lookback_days="${1:-${COST_ANALYSIS_LOOKBACK_DAYS}}"
    local end_date=$(date -u +"%Y-%m-%d")
    local start_date=$(date -u -d "${lookback_days} days ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-${lookback_days}d +"%Y-%m-%d" 2>/dev/null)
    
    echo "$start_date|$end_date"
}

# Get date range for previous period (for comparison)
get_previous_period_range() {
    local lookback_days="${1:-${COST_ANALYSIS_LOOKBACK_DAYS}}"
    # Previous period ends the day before current period starts, and goes back same number of days
    local prev_end_date=$(date -u -d "${lookback_days} days ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-${lookback_days}d +"%Y-%m-%d" 2>/dev/null)
    local prev_start_date=$(date -u -d "$((lookback_days * 2)) days ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-$((lookback_days * 2))d +"%Y-%m-%d" 2>/dev/null)
    
    echo "$prev_start_date|$prev_end_date"
}

# Query Azure Cost Management API with daily granularity (last 7 days)
query_daily_costs() {
    local subscription_id="$1"
    
    local daily_end_date=$(date -u +"%Y-%m-%d")
    local daily_start_date=$(date -u -d "7 days ago" +"%Y-%m-%d" 2>/dev/null || date -u -v-7d +"%Y-%m-%d" 2>/dev/null)
    
    log "📅 Querying daily costs for $subscription_id ($daily_start_date to $daily_end_date)"
    
    local query_json=$(cat <<EOF
{
  "type": "ActualCost",
  "timeframe": "Custom",
  "timePeriod": {
    "from": "${daily_start_date}T00:00:00Z",
    "to": "${daily_end_date}T23:59:59Z"
  },
  "dataset": {
    "granularity": "Daily",
    "aggregation": {
      "totalCost": {
        "name": "Cost",
        "function": "Sum"
      }
    }
  }
}
EOF
)
    
    local cost_data=$(az rest \
        --method post \
        --url "https://management.azure.com/subscriptions/${subscription_id}/providers/Microsoft.CostManagement/query?api-version=2021-10-01" \
        --body "$query_json" \
        --headers "Content-Type=application/json" \
        -o json 2>&1)
    
    # Parse using column names to handle any column order from the API
    echo "$cost_data" | jq '
        (.properties.columns // [] | to_entries | map({(.value.name): .key}) | add // {}) as $cols |
        [.properties.rows[]? | {
            date: (.[($cols["UsageDate"] // $cols["BillingMonth"] // 1)] | tostring | .[:10] |
                if test("^[0-9]{8}$") then .[:4] + "-" + .[4:6] + "-" + .[6:8] else . end),
            cost: ((.[($cols["Cost"] // $cols["PreTaxCost"] // 0)] // 0) | tonumber)
        }]
    '
}

# Query Azure Cost Management API
get_cost_data() {
    local subscription_id="$1"
    local start_date="$2"
    local end_date="$3"
    local resource_group_filter="$4"
    
    log "📊 Querying Azure Cost Management API..."
    log "   Subscription: $subscription_id"
    log "   Date range: $start_date to $end_date"
    log "   (This may take 30-60 seconds depending on data volume)"
    
    # Build the query JSON
    local query_json=$(cat <<EOF
{
  "type": "ActualCost",
  "timeframe": "Custom",
  "timePeriod": {
    "from": "${start_date}T00:00:00Z",
    "to": "${end_date}T23:59:59Z"
  },
  "dataset": {
    "granularity": "None",
    "aggregation": {
      "totalCost": {
        "name": "Cost",
        "function": "Sum"
      }
    },
    "grouping": [
      {
        "type": "Dimension",
        "name": "ResourceGroupName"
      },
      {
        "type": "Dimension",
        "name": "ServiceName"
      },
      {
        "type": "Dimension",
        "name": "MeterCategory"
      }
    ]
  }
}
EOF
)
    
    # Query the Cost Management API
    local cost_data=$(az rest \
        --method post \
        --url "https://management.azure.com/subscriptions/${subscription_id}/providers/Microsoft.CostManagement/query?api-version=2021-10-01" \
        --body "$query_json" \
        --headers "Content-Type=application/json" \
        -o json 2>&1)
    
    # Check for API errors
    if echo "$cost_data" | grep -qi "error\|failed\|forbidden\|unauthorized"; then
        log "   ⚠️  API Error Response:"
        echo "$cost_data" | jq -r '.error.message // .message // .' 2>/dev/null | sed 's/^/   /' >&2 || echo "$cost_data" | head -5 | sed 's/^/   /' >&2
    fi
    
    echo "$cost_data"
}

# Parse and aggregate cost data
parse_cost_data() {
    local cost_data="$1"
    
    # Extract rows and create structured data
    echo "$cost_data" | jq -r '
        .properties.rows[] | 
        {
            cost: (.[0] // 0),
            resourceGroup: (.[1] // "Unassigned"),
            serviceName: (.[2] // "Unknown"),
            meterCategory: (.[3] // "Unknown")
        }
    ' | jq -s '
        group_by(.resourceGroup) |
        map({
            resourceGroup: .[0].resourceGroup,
            totalCost: (map(.cost) | add),
            services: (
                group_by(.serviceName) |
                map({
                    serviceName: .[0].serviceName,
                    meterCategory: .[0].meterCategory,
                    cost: (map(.cost) | add)
                }) |
                sort_by(-.cost)
            )
        }) |
        sort_by(-.totalCost)
    '
}

# Generate table report
# Note: aggregated_data_file is a path to a temp JSON file (avoids ARG_MAX limits with large datasets)
generate_table_report() {
    local aggregated_data_file="$1"
    local start_date="$2"
    local end_date="$3"
    local total_cost="$4"
    local prev_total_cost="$5"
    local prev_start_date="$6"
    local prev_end_date="$7"
    local percent_change="$8"
    local cost_change="$9"
    local trend_icon="${10}"
    local trend_text="${11}"
    local daily_data_file="${12}"
    local prev_data_file="${13}"
    
    # Calculate summary statistics
    local rg_count=$(jq 'length' "$aggregated_data_file")
    local high_cost_rgs=$(jq --argjson total "$total_cost" --argjson threshold "$COST_CONCENTRATION_THRESHOLD" '[.[] | select((.totalCost / $total * 100) > $threshold)] | length' "$aggregated_data_file")
    local rgs_over_100=$(jq '[.[] | select(.totalCost > 100)] | length' "$aggregated_data_file")
    local rgs_under_1=$(jq '[.[] | select(.totalCost < 1)] | length' "$aggregated_data_file")
    local unique_subs=$(jq -r '[.[].subscriptionId // "unknown"] | unique | length' "$aggregated_data_file")
    
    # Get subscription breakdown
    local sub_breakdown=$(jq -r '
        group_by(.subscriptionId // "unknown") |
        map({
            subscription: (.[0].subscriptionName // .[0].subscriptionId // "unknown"),
            cost: (map(.totalCost) | add),
            rgCount: length
        }) |
        sort_by(-.cost) |
        map(
            "   ▸ " + 
            .subscription + 
            ": $" + 
            ((.cost * 100 | round) / 100 | tostring) + 
            " (" + (.rgCount | tostring) + " RGs)"
        ) |
        join("\n")
    ' "$aggregated_data_file")
    
    cat > "$REPORT_FILE" << EOF
╔══════════════════════════════════════════════════════════════════════════╗
║          AZURE COST REPORT - LAST ${COST_ANALYSIS_LOOKBACK_DAYS} DAYS                           ║
║          Period: $start_date to $end_date                      ║
╚══════════════════════════════════════════════════════════════════════════╝

📊 COST SUMMARY
$(printf '═%.0s' {1..72})

   💰 Total Cost Across All Subscriptions:  \$$total_cost
   📋 Subscriptions Analyzed:                $unique_subs
   📂 Total Resource Groups:                 $rg_count
   ⚠️  High Cost Contributors (>${COST_CONCENTRATION_THRESHOLD}%):        $high_cost_rgs
   📊 Resource Groups Over \$100:            $rgs_over_100
   📊 Resource Groups Under \$1:              $rgs_under_1

$(printf '═%.0s' {1..72})

📈 COST TREND ANALYSIS (vs Previous ${COST_ANALYSIS_LOOKBACK_DAYS} Days)
$(printf '═%.0s' {1..72})

   Current Period:  $start_date to $end_date = \$$total_cost
   Previous Period: $prev_start_date to $prev_end_date = \$$prev_total_cost
   
   Trend:        $trend_text $trend_icon
   Change:       \$$cost_change ($percent_change%)
   $(if (( $(echo "$percent_change >= $COST_INCREASE_THRESHOLD" | bc -l) )); then echo "   ⚠️  Alert:     Cost increase exceeds ${COST_INCREASE_THRESHOLD}% threshold"; elif (( $(echo "$percent_change > 0" | bc -l) )); then echo "   ℹ️  Status:    Within acceptable variance (<${COST_INCREASE_THRESHOLD}%)"; elif (( $(echo "$percent_change < 0" | bc -l) )); then echo "   ✅ Status:    Cost decreased - excellent!"; else echo "   ➡️  Status:    Cost remained stable"; fi)

$(printf '═%.0s' {1..72})

📋 COST BY SUBSCRIPTION:
$sub_breakdown

$(printf '═%.0s' {1..72})

EOF

    # Daily spend section (if daily data available)
    if [[ -n "$daily_data_file" && -f "$daily_data_file" ]]; then
        local daily_count=$(jq 'length' "$daily_data_file")
        if [[ $daily_count -gt 0 ]]; then
            cat >> "$REPORT_FILE" << 'DAILYHEADER'

📅 DAILY SPEND (LAST 7 DAYS)
DAILYHEADER
            printf '═%.0s' {1..72} >> "$REPORT_FILE"
            echo "" >> "$REPORT_FILE"
            echo "" >> "$REPORT_FILE"
            printf "   %-14s %s\n" "DATE" "COST" >> "$REPORT_FILE"
            printf '   ─%.0s' {1..40} >> "$REPORT_FILE"
            echo "" >> "$REPORT_FILE"

            jq -r 'sort_by(.date) | .[] | "   " + .date + "      $" + ((.cost * 100 | round) / 100 | tostring)' "$daily_data_file" >> "$REPORT_FILE"

            local daily_avg=$(jq '[.[].cost] | add / length | (. * 100 | round) / 100' "$daily_data_file")
            echo "" >> "$REPORT_FILE"
            echo "   7-day average: \$$daily_avg" >> "$REPORT_FILE"
            echo "" >> "$REPORT_FILE"

            # Anomaly detection (skip when average is zero to avoid flagging all days)
            local anomalies='[]'
            local anomaly_count=0
            if (( $(echo "$daily_avg > 0" | bc -l) )); then
                anomalies=$(jq --argjson avg "$daily_avg" '[.[] | select(.cost >= ($avg * 2))]' "$daily_data_file")
                anomaly_count=$(echo "$anomalies" | jq 'length')
            fi
            if [[ $anomaly_count -gt 0 ]]; then
                cat >> "$REPORT_FILE" << 'ANOMALYHEADER'
🔍  ANOMALY DETECTION
ANOMALYHEADER
                printf '   ─%.0s' {1..40} >> "$REPORT_FILE"
                echo "" >> "$REPORT_FILE"
                echo "   Days with spend ≥2x the 7-day average (\$$daily_avg):" >> "$REPORT_FILE"
                echo "$anomalies" | jq -r '.[] | "   ⚠️  " + .date + ": $" + ((.cost * 100 | round) / 100 | tostring)' >> "$REPORT_FILE"
                echo "" >> "$REPORT_FILE"
            else
                echo "   ✅ No anomalies detected (no day exceeded 2x the average)" >> "$REPORT_FILE"
                echo "" >> "$REPORT_FILE"
            fi
        fi
    fi

    cat >> "$REPORT_FILE" << EOF
$(printf '═%.0s' {1..72})

📊 ALL RESOURCE GROUPS BY COST ($rg_count total)
$(printf '═%.0s' {1..72})

   RESOURCE GROUP                   SUBSCRIPTION                     COST      %
$(printf '─%.0s' {1..72})

EOF

    # Generate complete resource group summary table with subscription info
    jq -r --argjson total "$total_cost" '
        to_entries |
        map(
            ((.key + 1) | tostring | if length == 1 then " " + . else . end) + 
            ". " + 
            (.value.resourceGroup | 
                if length > 32 then .[:29] + "..." else . + (" " * (32 - length)) end
            ) + 
            "  " +
            ((.value.subscriptionName // .value.subscriptionId // "unknown") | 
             if length > 28 then .[:25] + "..." else . + (" " * (28 - length)) end
            ) +
            "  $" + 
            ((.value.totalCost | . * 100 | round / 100 | tostring) as $cost |
             if ($cost | contains(".")) then
                 ($cost | split(".") | 
                  if (.[1] | length) == 1 then .[0] + "." + .[1] + "0"
                  else $cost end)
             else
                 $cost + ".00"
             end |
             if length < 9 then (" " * (9 - length)) + . else . end
            ) + 
            "  (" + 
            ((.value.totalCost / $total * 100) | floor | tostring | 
                if length == 1 then " " + . else . end
            ) + 
            "%)"
        ) |
        join("\n")
    ' "$aggregated_data_file" >> "$REPORT_FILE"

    cat >> "$REPORT_FILE" << EOF

$(printf '═%.0s' {1..72})

📋 DETAILED BREAKDOWN BY RESOURCE GROUP
$(printf '═%.0s' {1..72})

EOF
    
    # Generate detailed report for each resource group (all RGs, all services)
    jq -r --arg sep "$(printf '═%.0s' {1..72})" --argjson total "$total_cost" --argjson threshold "$COST_CONCENTRATION_THRESHOLD" '
        .[] | 
        "
📂 RESOURCE GROUP: " + .resourceGroup + 
(if .subscriptionName then " (Subscription: " + .subscriptionName + ")" else "" end) + "
   Total Cost: $" + ((.totalCost * 100 | round) / 100 | tostring) + " (" + ((.totalCost / $total * 100) | floor | tostring) + "% of total)
   " + (if (.totalCost / $total * 100) > $threshold then "⚠️  HIGH COST CONTRIBUTOR" else "" end) + "
   
   Services:
" + (
    .services | 
    map("      ▸ " + .serviceName + ": $" + ((.cost * 100 | round) / 100 | tostring) + " (" + .meterCategory + ")") | 
    join("\n")
) + "
" + $sep
    ' "$aggregated_data_file" >> "$REPORT_FILE"
    
    # Generate top 10 services overall
    cat >> "$REPORT_FILE" << EOF

╔══════════════════════════════════════════════════════════════════════════╗
║          TOP 10 MOST EXPENSIVE SERVICES                              ║
╚══════════════════════════════════════════════════════════════════════════╝

EOF
    
    jq -r '
        [.[] | .services[]] |
        sort_by(-.cost) |
        .[:10] |
        to_entries |
        map(((.key + 1) | tostring) + ". " + .value.serviceName + " - $" + ((.value.cost * 100 | round) / 100 | tostring)) |
        join("\n")
    ' "$aggregated_data_file" >> "$REPORT_FILE"
    
    # Top cost movers section (if previous period data available)
    if [[ -n "$prev_data_file" && -f "$prev_data_file" ]]; then
        cat >> "$REPORT_FILE" << EOF

╔══════════════════════════════════════════════════════════════════════════╗
║          TOP COST CHANGES BY SERVICE                                 ║
╚══════════════════════════════════════════════════════════════════════════╝

EOF

        jq -n \
            --slurpfile current "$aggregated_data_file" \
            --slurpfile previous "$prev_data_file" \
            '
            def flatten_services:
                [.[][] | .services[] | {serviceName: .serviceName, cost: .cost}] |
                group_by(.serviceName) |
                map({serviceName: .[0].serviceName, cost: (map(.cost) | add)});
            ($current | flatten_services) as $cur |
            ($previous | flatten_services) as $prev |
            [
                ($cur[] | . as $c |
                    ($prev | map(select(.serviceName == $c.serviceName)) | .[0].cost // 0) as $pc |
                    {serviceName: $c.serviceName, current: $c.cost, previous: $pc, change: ($c.cost - $pc)}
                ),
                ($prev[] | . as $p |
                    if ($cur | map(select(.serviceName == $p.serviceName)) | length) == 0 then
                        {serviceName: $p.serviceName, current: 0, previous: $p.cost, change: (0 - $p.cost)}
                    else empty end
                )
            ] |
            sort_by(-((.change | abs) // 0)) |
            .[:15] |
            to_entries |
            map(
                ((.key + 1) | tostring | if length == 1 then " " + . else . end) + ". " +
                (.value.serviceName | if length > 35 then .[:32] + "..." else . + (" " * (35 - length)) end) +
                (if .value.change >= 0 then "  +" else "  " end) +
                "$" + ((.value.change | . * 100 | round / 100 | tostring)) +
                "  ($" + ((.value.previous | . * 100 | round / 100 | tostring)) + " → $" + ((.value.current | . * 100 | round / 100 | tostring)) + ")"
            ) |
            join("\n")
        ' >> "$REPORT_FILE"
    fi

    cat >> "$REPORT_FILE" << EOF

$(printf '═%.0s' {1..72})

💡 COST OPTIMIZATION TIPS:
   ▸ Review high-cost resource groups for optimization opportunities
   ▸ Check for unused or underutilized resources
   ▸ Consider reserved instances for predictable workloads
   ▸ Enable Azure Advisor for personalized recommendations
   ▸ Review storage tiers and lifecycle policies

EOF
}

# Generate CSV report
# Note: aggregated_data_file is a path to a temp JSON file
generate_csv_report() {
    local aggregated_data_file="$1"
    
    echo "SubscriptionId,ResourceGroup,ServiceName,MeterCategory,Cost" > "$CSV_FILE"
    
    jq -r '
        .[] |
        .resourceGroup as $rg |
        .subscriptionId as $sub |
        .services[] |
        [$sub, $rg, .serviceName, .meterCategory, (.cost | tostring)] |
        @csv
    ' "$aggregated_data_file" >> "$CSV_FILE"
    
    log "CSV report saved to: $CSV_FILE"
}

# Generate JSON report
# Note: aggregated_data_file is a path to a temp JSON file
generate_json_report() {
    local aggregated_data_file="$1"
    local start_date="$2"
    local end_date="$3"
    local total_cost="$4"
    
    jq -n \
        --arg startDate "$start_date" \
        --arg endDate "$end_date" \
        --arg totalCost "$total_cost" \
        --slurpfile data "$aggregated_data_file" \
        '{
            reportPeriod: {
                startDate: $startDate,
                endDate: $endDate
            },
            totalCost: ($totalCost | tonumber),
            currency: "USD",
            resourceGroups: $data[0]
        }' > "$JSON_FILE"
    
    log "JSON report saved to: $JSON_FILE"
}

# Get subscription name from ID
get_subscription_name() {
    local subscription_id="$1"
    local sub_name=$(az account show --subscription "$subscription_id" --query "name" -o tsv 2>/dev/null || echo "")
    if [[ -z "$sub_name" ]]; then
        # Fallback to ID if name not available
        echo "$subscription_id"
    else
        echo "$sub_name"
    fi
}

# Process a single subscription
process_subscription() {
    local subscription_id="$1"
    local start_date="$2"
    local end_date="$3"
    
    log "═══════════════════════════════════════════════"
    log "📌 Processing subscription: $subscription_id"
    log "═══════════════════════════════════════════════"
    
    # Get subscription name
    log "   Retrieving subscription details..."
    local sub_name=$(get_subscription_name "$subscription_id")
    log "   ✅ Subscription name: $sub_name"
    
    # Get cost data from Azure
    local cost_data=$(get_cost_data "$subscription_id" "$start_date" "$end_date" "$RESOURCE_GROUPS")
    
    # Check if we got valid data
    local row_count=$(echo "$cost_data" | jq '.properties.rows // [] | length' 2>/dev/null || echo "0")
    if [[ $row_count -eq 0 ]]; then
        log "⚠️  Subscription $subscription_id: No cost data returned"
        
        # Check if it's an error response
        local error_code=$(echo "$cost_data" | jq -r '.error.code // empty' 2>/dev/null)
        local error_msg=$(echo "$cost_data" | jq -r '.error.message // empty' 2>/dev/null)
        
        if [[ -n "$error_code" ]]; then
            log "   ❌ API Error: $error_code"
            log "   Message: $error_msg"
        else
            # Successful response but no data
            log "   Possible reasons:"
            log "   • No costs incurred in the date range ($start_date to $end_date)"
            log "   • Cost data still processing (can take 24-48 hours)"
            log "   • All costs are \$0 (free tier resources)"
            
            # Debug: Show first few properties
            local props_preview=$(echo "$cost_data" | jq -r '.properties | keys' 2>/dev/null)
            if [[ -n "$props_preview" && "$props_preview" != "null" ]]; then
                log "   🔍  API Response properties: $props_preview"
            fi
        fi
        return 1
    fi
    
    log "✅ Retrieved $row_count cost records from subscription $sub_name"
    
    # Parse and aggregate data
    log "   Processing and aggregating cost data..."
    local aggregated_data=$(parse_cost_data "$cost_data")
    
    # Add subscription ID and name to each resource group entry
    aggregated_data=$(echo "$aggregated_data" | jq --arg sub "$subscription_id" --arg subName "$sub_name" 'map(. + {subscriptionId: $sub, subscriptionName: $subName})')
    
    local rg_count=$(echo "$aggregated_data" | jq 'length')
    log "   ✅ Aggregated costs across $rg_count resource group(s)"
    log ""
    
    echo "$aggregated_data"
}

# Compare current and previous period costs and generate trend analysis
compare_periods() {
    local current_cost="$1"
    local previous_cost="$2"
    local current_start="$3"
    local current_end="$4"
    local previous_start="$5"
    local previous_end="$6"
    local aggregated_data_file="$7"
    
    # Calculate change
    local cost_change=$(echo "scale=2; $current_cost - $previous_cost" | bc -l)
    local cost_change_abs=$(echo "$cost_change" | tr -d '-')
    
    # Calculate percentage change
    local percent_change="0"
    if (( $(echo "$previous_cost > 0" | bc -l) )); then
        percent_change=$(echo "scale=2; ($cost_change / $previous_cost) * 100" | bc -l)
    fi
    
    local percent_change_abs=$(echo "$percent_change" | tr -d '-')
    
    # Determine trend
    local trend_icon="➡️"
    local trend_text="No significant change"
    local severity=4
    
    if (( $(echo "$percent_change > 0" | bc -l) )); then
        trend_icon="📈"
        trend_text="INCREASING"
        
        # Check if exceeds threshold
        if (( $(echo "$percent_change >= $COST_INCREASE_THRESHOLD" | bc -l) )); then
            severity=3
            if (( $(echo "$percent_change >= 25" | bc -l) )); then
                severity=2  # High severity for 25%+ increase
            fi
        fi
    elif (( $(echo "$percent_change < 0" | bc -l) )); then
        trend_icon="📉"
        trend_text="DECREASING"
    fi
    
    # Accumulate all issues in a temp file
    local issues_temp=$(mktemp "$TEMP_DIR/azure_cost_issues_XXXXXX.json")
    echo '[]' > "$issues_temp"

    # Trend issue
    if (( $(echo "$percent_change >= $COST_INCREASE_THRESHOLD" | bc -l) )); then
        local issue_details="AZURE COST TREND ALERT - SIGNIFICANT INCREASE DETECTED

COST COMPARISON:
══════════════════════════════════════════════════════════════

Current Period ($current_start to $current_end):
  Total Cost: \$$current_cost

Previous Period ($previous_start to $previous_end):
  Total Cost: \$$previous_cost

CHANGE ANALYSIS:
  Absolute Change: \$$cost_change_abs
  Percentage Change: ${percent_change}%
  Trend: $trend_text $trend_icon
  
ALERT THRESHOLD: ${COST_INCREASE_THRESHOLD}%
══════════════════════════════════════════════════════════════

IMPACT:
Your Azure costs have increased by ${percent_change}%, which exceeds the configured alert threshold of ${COST_INCREASE_THRESHOLD}%.

This represents an additional \$$cost_change_abs spend compared to the previous ${COST_ANALYSIS_LOOKBACK_DAYS}-day period.

RECOMMENDED ACTIONS:
1. Review the detailed cost report for service-level breakdowns
2. Identify which services/resource groups show the largest increases
3. Check for:
   - New resources or services deployed
   - Unexpected scaling events or autoscaling changes
   - Data transfer or bandwidth increases
   - Licensing or tier changes
   - Runaway workloads or misconfigured resources
4. Run the specialized cost optimization codebundles:
   - azure-vm-cost-optimization: VM rightsizing and deallocation analysis
   - azure-aks-cost-optimization: AKS node pool optimization
   - azure-appservice-cost-optimization: App Service Plan rightsizing
   - azure-storage-cost-optimization: Orphaned disks, snapshots, lifecycle policies
   - azure-databricks-cost-optimization: Databricks cluster auto-termination
5. Set up budget alerts in Azure Cost Management for proactive monitoring"

        local next_steps="IMMEDIATE ACTIONS:

1. Review Detailed Cost Report:
   • Check azure_cost_report.txt for service and resource group breakdown
   • Compare top spending services between periods
   
2. Investigate Top Cost Drivers:
   • Azure Portal → Cost Management → Cost Analysis
   • Filter by date range: $current_start to $current_end
   • Group by Service Name and Resource Group
   
3. Run Specialized Cost Optimization Codebundles:
   • azure-vm-cost-optimization - Find oversized/stopped VMs for rightsizing
   • azure-aks-cost-optimization - Analyze AKS node pool utilization
   • azure-appservice-cost-optimization - Identify empty/underutilized App Service Plans
   • azure-storage-cost-optimization - Find orphaned disks, old snapshots
   • azure-databricks-cost-optimization - Check cluster auto-termination settings
   
4. Establish Cost Governance:
   • Set up Azure Budget alerts
   • Implement resource tagging for cost allocation
   • Review and rightsize overprovisioned resources
   
5. Monitor Trends:
   • Schedule regular cost reports (weekly/monthly)
   • Track month-over-month spending
   • Identify and address cost anomalies early"

        local trend_issue=$(jq -n \
            --arg title "Azure Cost Increase: ${percent_change}% (\$${cost_change_abs} increase over ${COST_ANALYSIS_LOOKBACK_DAYS} days)" \
            --arg details "$issue_details" \
            --arg next_steps "$next_steps" \
            --argjson severity "$severity" \
            '{title: $title, details: $details, severity: $severity, next_step: $next_steps}')
        
        jq --argjson issue "$trend_issue" '. + [$issue]' "$issues_temp" > "${issues_temp}.tmp" && mv "${issues_temp}.tmp" "$issues_temp"
    fi
    
    # Budget check
    if (( $(echo "$COST_BUDGET > 0" | bc -l) )) && (( $(echo "$current_cost > $COST_BUDGET" | bc -l) )); then
        local overage=$(echo "scale=2; $current_cost - $COST_BUDGET" | bc -l)
        local overage_pct=$(echo "scale=2; ($overage / $COST_BUDGET) * 100" | bc -l)
        local budget_issue=$(jq -n \
            --arg title "Azure Cost Budget Exceeded: \$${current_cost} spent vs \$${COST_BUDGET} budget" \
            --arg details "Azure costs of \$${current_cost} have exceeded the configured budget of \$${COST_BUDGET} by \$${overage} (${overage_pct}% over budget) for the period ${current_start} to ${current_end}." \
            --arg next_steps "Review spending and identify areas to reduce costs. Consider adjusting the budget if the increase is expected, or investigate unexpected cost drivers." \
            '{title: $title, details: $details, severity: 3, next_step: $next_steps}')
        
        jq --argjson issue "$budget_issue" '. + [$issue]' "$issues_temp" > "${issues_temp}.tmp" && mv "${issues_temp}.tmp" "$issues_temp"
    fi
    
    # Concentration check
    if [[ -n "$aggregated_data_file" && -f "$aggregated_data_file" ]] && (( $(echo "$current_cost > 0" | bc -l) )); then
        local concentrated_rgs=$(jq --argjson total "$current_cost" --argjson threshold "$COST_CONCENTRATION_THRESHOLD" \
            '[.[] | select((.totalCost / $total * 100) > $threshold) | {resourceGroup: .resourceGroup, pct: ((.totalCost / $total * 100) | . * 100 | round / 100)}]' "$aggregated_data_file")
        local conc_count=$(echo "$concentrated_rgs" | jq 'length')
        if [[ $conc_count -gt 0 ]]; then
            local conc_rg_list=$(echo "$concentrated_rgs" | jq -r '[.[] | .resourceGroup + " (" + (.pct | tostring) + "%)"] | join(", ")')
            local conc_issue=$(jq -n \
                --arg title "Azure Cost Concentration Risk: ${conc_count} resource group(s) exceed ${COST_CONCENTRATION_THRESHOLD}% of total spend" \
                --arg details "The following resource group(s) each represent more than ${COST_CONCENTRATION_THRESHOLD}% of total Azure costs (\$${current_cost}): ${conc_rg_list}. High cost concentration in a small number of resource groups increases risk exposure." \
                --arg next_steps "Review the concentrated resource groups for optimization opportunities. Consider distributing workloads or evaluating whether the cost concentration is expected and justified." \
                '{title: $title, details: $details, severity: 3, next_step: $next_steps}')
            
            jq --argjson issue "$conc_issue" '. + [$issue]' "$issues_temp" > "${issues_temp}.tmp" && mv "${issues_temp}.tmp" "$issues_temp"
        fi
    fi
    
    # Write all accumulated issues to the issues file
    cp "$issues_temp" "$ISSUES_FILE"
    rm -f "$issues_temp"
    
    # Return trend info for report
    echo "${percent_change}|${cost_change}|${trend_icon}|${trend_text}"
}

# Main function
main() {
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo "║   Azure Cost Report Generation                                    ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo ""
    log "🚀 Starting cost report generation at $(date '+%Y-%m-%d %H:%M:%S')"
    log ""
    
    if [[ -z "$SUBSCRIPTION_IDS" ]]; then
        echo "❌ Error: AZURE_SUBSCRIPTION_IDS environment variable not set"
        exit 1
    fi
    
    local sub_count=$(echo "$SUBSCRIPTION_IDS" | tr ',' '\n' | wc -l)
    log "🎯 Target: $sub_count subscription(s)"
    log "📂 Resource groups: ${RESOURCE_GROUPS:-ALL}"
    log "📈 Cost trend analysis: ENABLED (threshold: ${COST_INCREASE_THRESHOLD}%)"
    log ""
    
    # Get date ranges for current and previous periods
    local dates=$(get_date_range)
    IFS='|' read -r start_date end_date <<< "$dates"
    
    local prev_dates=$(get_previous_period_range)
    IFS='|' read -r prev_start_date prev_end_date <<< "$prev_dates"
    
    log "📅 Current period: $start_date to $end_date (${COST_ANALYSIS_LOOKBACK_DAYS} days)"
    log "📅 Previous period: $prev_start_date to $prev_end_date (${COST_ANALYSIS_LOOKBACK_DAYS} days)"
    log ""
    
    # Process multiple subscriptions
    local all_aggregated_data='[]'
    local successful_subs=0
    local failed_subs=0
    local failed_sub_ids=""
    
    IFS=',' read -ra SUB_ARRAY <<< "$SUBSCRIPTION_IDS"
    local total_subs=${#SUB_ARRAY[@]}
    local current_sub=0
    
    for sub_id in "${SUB_ARRAY[@]}"; do
        sub_id=$(echo "$sub_id" | xargs)  # trim whitespace
        ((current_sub++))
        
        log "───────────────────────────────────────────────"
        log "Processing subscription [$current_sub/$total_subs]"
        log "───────────────────────────────────────────────"
        
        local sub_data=$(process_subscription "$sub_id" "$start_date" "$end_date")
        if [[ $? -eq 0 && -n "$sub_data" && "$sub_data" != "[]" ]]; then
            # Merge this subscription's data with the overall data
            # Use temp file to avoid "Argument list too long" error with large datasets
            local temp_sub_file=$(mktemp "$TEMP_DIR/azure_cost_sub_XXXXXX.json")
            echo "$sub_data" > "$temp_sub_file"
            all_aggregated_data=$(echo "$all_aggregated_data" | jq --slurpfile new "$temp_sub_file" '. + $new[0]')
            rm -f "$temp_sub_file"
            ((successful_subs++))
            log "✅ Successfully processed subscription $current_sub/$total_subs"
        else
            ((failed_subs++))
            failed_sub_ids="${failed_sub_ids}${sub_id}, "
            log "⚠️  Failed to process subscription $current_sub/$total_subs"
        fi
        log ""
    done
    
    # Write aggregated data to temp file (avoids ARG_MAX limits with hundreds of resource groups)
    local aggregated_data_file=$(mktemp "$TEMP_DIR/azure_cost_aggregated_XXXXXX.json")
    echo "$all_aggregated_data" | jq 'sort_by(-.totalCost)' > "$aggregated_data_file"
    
    log "Successfully processed $successful_subs subscription(s)"
    if [[ $failed_subs -gt 0 ]]; then
        failed_sub_ids=${failed_sub_ids%, }  # Remove trailing comma
        log "⚠️  Failed to retrieve cost data from $failed_subs subscription(s): $failed_sub_ids"
    fi
    
    # Check if we have any data at all
    local total_rg_count=$(jq 'length' "$aggregated_data_file")
    if [[ $total_rg_count -eq 0 ]]; then
        log "❌ No cost data available from any subscription"
        
        cat > "$REPORT_FILE" << EOF
╔══════════════════════════════════════════════════════════════════════════╗
║          AZURE COST REPORT - LAST 30 DAYS                           ║
║          Period: $start_date to $end_date                      ║
╚══════════════════════════════════════════════════════════════════════════╝

⚠️  NO COST DATA AVAILABLE FROM ANY SUBSCRIPTION

Subscriptions attempted: ${#SUB_ARRAY[@]}
Subscriptions with errors: $failed_subs

Failed subscriptions: $failed_sub_ids

Possible reasons:
• No costs incurred during this period
• Insufficient permissions (need Cost Management Reader or Contributor)
• Cost data not yet processed (can take 24-48 hours)
• Subscription ID(s) incorrect

Please verify:
1. You have Cost Management Reader role on all subscriptions
2. Costs have been incurred in the last 30 days
3. Cost data has been processed by Azure

EOF
        log "Report saved to: $REPORT_FILE"
        echo '[]' > "$ISSUES_FILE"
        exit 0
    fi
    
    # Calculate total cost for current period (rounded to 2 decimal places)
    local total_cost=$(jq '[.[].totalCost] | add // 0 | (. * 100 | round) / 100' "$aggregated_data_file")
    
    log "Total cost (current period): \$$total_cost"
    
    # Query previous period for trend comparison
    log ""
    log "───────────────────────────────────────────────"
    log "Querying previous period for cost trend analysis..."
    log "───────────────────────────────────────────────"
    
    local prev_all_aggregated_data='[]'
    local prev_successful_subs=0
    
    for sub_id in "${SUB_ARRAY[@]}"; do
        sub_id=$(echo "$sub_id" | xargs)
        log "Fetching previous period data for subscription: $sub_id"
        
        local prev_sub_data=$(process_subscription "$sub_id" "$prev_start_date" "$prev_end_date")
        if [[ $? -eq 0 && -n "$prev_sub_data" && "$prev_sub_data" != "[]" ]]; then
            local temp_prev_file=$(mktemp "$TEMP_DIR/azure_cost_prev_XXXXXX.json")
            echo "$prev_sub_data" > "$temp_prev_file"
            prev_all_aggregated_data=$(echo "$prev_all_aggregated_data" | jq --slurpfile new "$temp_prev_file" '. + $new[0]')
            rm -f "$temp_prev_file"
            ((prev_successful_subs++))
        fi
    done
    
    local prev_total_cost=$(echo "$prev_all_aggregated_data" | jq '[.[].totalCost] | add // 0 | (. * 100 | round) / 100')
    
    # Write previous period data to temp file for report generation
    local prev_data_file=$(mktemp "$TEMP_DIR/azure_cost_prev_aggregated_XXXXXX.json")
    echo "$prev_all_aggregated_data" | jq 'sort_by(-.totalCost)' > "$prev_data_file"
    
    log "Total cost (previous period): \$$prev_total_cost"
    log "Previous period data retrieved from $prev_successful_subs subscription(s)"
    log ""
    
    # Query daily costs (last 7 days) for time-series and anomaly detection
    log "Querying daily costs (last 7 days)..."
    local all_daily_data='[]'
    for sub_id in "${SUB_ARRAY[@]}"; do
        sub_id=$(echo "$sub_id" | xargs)
        local daily_parsed=$(query_daily_costs "$sub_id")
        if [[ -n "$daily_parsed" && "$daily_parsed" != "[]" && "$daily_parsed" != "null" ]]; then
            all_daily_data=$(echo "$all_daily_data" | jq --argjson new "$daily_parsed" '. + $new')
        fi
    done
    # Aggregate daily costs by date across all subscriptions
    local daily_data_file=$(mktemp "$TEMP_DIR/azure_cost_daily_XXXXXX.json")
    echo "$all_daily_data" | jq 'group_by(.date) | map({date: .[0].date, cost: (map(.cost) | add)}) | sort_by(.date)' > "$daily_data_file"
    log "Daily cost data collected"
    log ""
    
    # Compare periods and generate trend analysis
    local trend_data=$(compare_periods "$total_cost" "$prev_total_cost" "$start_date" "$end_date" "$prev_start_date" "$prev_end_date" "$aggregated_data_file")
    IFS='|' read -r percent_change cost_change trend_icon trend_text <<< "$trend_data"
    
    log "═══════════════════════════════════════════════"
    log "COST TREND ANALYSIS"
    log "═══════════════════════════════════════════════"
    log "Trend: $trend_text $trend_icon"
    log "Change: \$${cost_change} (${percent_change}%)"
    
    if (( $(echo "$percent_change >= $COST_INCREASE_THRESHOLD" | bc -l) )); then
        log "⚠️  ALERT: Cost increase exceeds threshold of ${COST_INCREASE_THRESHOLD}%"
        log "   Issue generated in: $ISSUES_FILE"
    elif (( $(echo "$percent_change > 0" | bc -l) )); then
        log "ℹ️  Cost increased but within acceptable threshold (<${COST_INCREASE_THRESHOLD}%)"
    elif (( $(echo "$percent_change < 0" | bc -l) )); then
        log "✅ Cost decreased - great job optimizing!"
    else
        log "➡️  Cost remained stable"
    fi
    log "═══════════════════════════════════════════════"
    log ""
    
    # Generate reports (pass file path instead of data string to avoid ARG_MAX)
    if [[ "$OUTPUT_FORMAT" == "csv" || "$OUTPUT_FORMAT" == "all" ]]; then
        generate_csv_report "$aggregated_data_file"
    fi
    
    if [[ "$OUTPUT_FORMAT" == "json" || "$OUTPUT_FORMAT" == "all" ]]; then
        generate_json_report "$aggregated_data_file" "$start_date" "$end_date" "$total_cost"
    fi
    
    if [[ "$OUTPUT_FORMAT" == "table" || "$OUTPUT_FORMAT" == "all" ]]; then
        generate_table_report "$aggregated_data_file" "$start_date" "$end_date" "$total_cost" "$prev_total_cost" "$prev_start_date" "$prev_end_date" "$percent_change" "$cost_change" "$trend_icon" "$trend_text" "$daily_data_file" "$prev_data_file"
        log "Report saved to: $REPORT_FILE"
        echo ""
        cat "$REPORT_FILE"
        
        # Also output top 5 resource groups summary to stderr for easy parsing
        if [[ -f "$JSON_FILE" ]]; then
            echo "" >&2
            echo "📊 Top 5 Resource Groups by Cost:" >&2
            jq -r '.resourceGroups[:5] | .[] | "  ▸ " + .resourceGroup + ": $" + (.totalCost * 100 | round / 100 | tostring)' "$JSON_FILE" 2>/dev/null | sed 's/^/  /' >&2 || true
        fi
    fi
    
    echo ""
    log "══════════════════════════════════════════════════"
    log "✅ Cost report generation complete!"
    log "══════════════════════════════════════════════════"
    log "   Finished at: $(date '+%Y-%m-%d %H:%M:%S')"
    log "   Successful subscriptions: $successful_subs/$total_subs"
    if [[ $failed_subs -gt 0 ]]; then
        failed_sub_ids=${failed_sub_ids%, }
        log "   ⚠️  Failed subscriptions: $failed_subs ($failed_sub_ids)"
    fi
    log "   Report file: $REPORT_FILE"
    log ""

    rm -f "$aggregated_data_file" "$prev_data_file" "$daily_data_file" 2>/dev/null || true
}

main "$@"
