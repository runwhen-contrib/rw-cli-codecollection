#!/bin/bash

# Azure Cost Report by Service and Resource Group
# Generates a detailed cost breakdown for the last 30 days

# Environment Variables
SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID}"
RESOURCE_GROUPS="${AZURE_RESOURCE_GROUPS:-all}"  # comma-separated or "all"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-table}"  # table, csv, json
REPORT_FILE="${REPORT_FILE:-azure_cost_report.txt}"
CSV_FILE="${CSV_FILE:-azure_cost_report.csv}"
JSON_FILE="${JSON_FILE:-azure_cost_report.json}"

# Logging function
log() {
    echo "💰 [$(date '+%H:%M:%S')] $*" >&2
}

# Get date range (last 30 days)
get_date_range() {
    local end_date=$(date -u +"%Y-%m-%d")
    local start_date=$(date -u -d '30 days ago' +"%Y-%m-%d" 2>/dev/null || date -u -v-30d +"%Y-%m-%d" 2>/dev/null)
    
    echo "$start_date|$end_date"
}

# Query Azure Cost Management API
get_cost_data() {
    local subscription_id="$1"
    local start_date="$2"
    local end_date="$3"
    local resource_group_filter="$4"
    
    log "Querying Azure Cost Management API for costs from $start_date to $end_date..."
    
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
        -o json 2>/dev/null || echo '{}')
    
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
generate_table_report() {
    local aggregated_data="$1"
    local start_date="$2"
    local end_date="$3"
    local total_cost="$4"
    
    # Calculate summary statistics
    local rg_count=$(echo "$aggregated_data" | jq 'length')
    local high_cost_rgs=$(echo "$aggregated_data" | jq --argjson total "$total_cost" '[.[] | select((.totalCost / $total * 100) > 20)] | length')
    local rgs_over_100=$(echo "$aggregated_data" | jq '[.[] | select(.totalCost > 100)] | length')
    local rgs_under_1=$(echo "$aggregated_data" | jq '[.[] | select(.totalCost < 1)] | length')
    local unique_subs=$(echo "$aggregated_data" | jq -r '[.[].subscriptionId // "unknown"] | unique | length')
    
    # Get subscription breakdown
    local sub_breakdown=$(echo "$aggregated_data" | jq -r '
        group_by(.subscriptionId // "unknown") |
        map({
            subscription: (.[0].subscriptionName // .[0].subscriptionId // "unknown"),
            cost: (map(.totalCost) | add),
            rgCount: length
        }) |
        sort_by(-.cost) |
        map(
            "   • " + 
            .subscription + 
            ": $" + 
            ((.cost * 100 | round) / 100 | tostring) + 
            " (" + (.rgCount | tostring) + " RGs)"
        ) |
        join("\n")
    ')
    
    cat > "$REPORT_FILE" << EOF
╔══════════════════════════════════════════════════════════════════════╗
║          AZURE COST REPORT - LAST 30 DAYS                           ║
║          Period: $start_date to $end_date                      ║
╚══════════════════════════════════════════════════════════════════════╝

📊 COST SUMMARY
$(printf '═%.0s' {1..72})

   💰 Total Cost Across All Subscriptions:  \$$total_cost
   🔐 Subscriptions Analyzed:                $unique_subs
   📦 Total Resource Groups:                 $rg_count
   ⚠️  High Cost Contributors (>20%):        $high_cost_rgs
   🔥 Resource Groups Over \$100:            $rgs_over_100
   💤 Resource Groups Under \$1:              $rgs_under_1

$(printf '─%.0s' {1..72})

💳 COST BY SUBSCRIPTION:
$sub_breakdown

$(printf '═%.0s' {1..72})

📋 TOP 10 RESOURCE GROUPS BY COST
$(printf '═%.0s' {1..72})

   RESOURCE GROUP                        SUBSCRIPTION              COST      %
$(printf '─%.0s' {1..72})

EOF

    # Generate top 10 resource groups summary table with subscription info
    echo "$aggregated_data" | jq -r --argjson total "$total_cost" '
        .[:10] |
        to_entries |
        map(
            ((.key + 1) | tostring | if length == 1 then " " + . else . end) + 
            ". " + 
            (.value.resourceGroup | 
                if length > 35 then .[:32] + "..." else . + (" " * (35 - length)) end
            ) + 
            "  " +
            ((.value.subscriptionName // .value.subscriptionId // "unknown") | 
             if length > 20 then .[:17] + "..." else . + (" " * (20 - length)) end
            ) +
            "  $" + 
            ((.value.totalCost * 100 | round) / 100 | tostring | 
                if length < 8 then (" " * (8 - length)) + . else . end
            ) + 
            "  (" + 
            ((.value.totalCost / $total * 100) | floor | tostring | 
                if length == 1 then " " + . else . end
            ) + 
            "%)"
        ) |
        join("\n")
    ' >> "$REPORT_FILE"

    cat >> "$REPORT_FILE" << EOF

$(printf '═%.0s' {1..72})

🔍 DETAILED BREAKDOWN BY RESOURCE GROUP
$(printf '═%.0s' {1..72})

EOF
    
    # Generate report by resource group
    echo "$aggregated_data" | jq -r --arg sep "$(printf '─%.0s' {1..72})" '
        .[] | 
        "
🔹 RESOURCE GROUP: " + .resourceGroup + 
(if .subscriptionName then " (Subscription: " + .subscriptionName + ")" else "" end) + "
   Total Cost: $" + ((.totalCost * 100 | round) / 100 | tostring) + " (" + ((.totalCost / '$total_cost' * 100) | floor | tostring) + "% of total)
   " + (if (.totalCost / '$total_cost' * 100) > 20 then "⚠️  HIGH COST CONTRIBUTOR" else "" end) + "
   
   Top Services:
" + (
    .services[:10] | 
    map("      • " + .serviceName + ": $" + ((.cost * 100 | round) / 100 | tostring) + " (" + .meterCategory + ")") | 
    join("\n")
) + "
   " + (if (.services | length) > 10 then "... and " + ((.services | length) - 10 | tostring) + " more services" else "" end) + "
" + $sep
    ' >> "$REPORT_FILE"
    
    # Generate top 10 services overall
    cat >> "$REPORT_FILE" << EOF

╔══════════════════════════════════════════════════════════════════════╗
║          TOP 10 MOST EXPENSIVE SERVICES                              ║
╚══════════════════════════════════════════════════════════════════════╝

EOF
    
    echo "$aggregated_data" | jq -r '
        [.[] | .services[]] |
        sort_by(-.cost) |
        .[:10] |
        to_entries |
        map(((.key + 1) | tostring) + ". " + .value.serviceName + " - $" + ((.value.cost * 100 | round) / 100 | tostring)) |
        join("\n")
    ' >> "$REPORT_FILE"
    
    cat >> "$REPORT_FILE" << EOF

$(printf '═%.0s' {1..72})

📈 COST OPTIMIZATION TIPS:
   • Review high-cost resource groups for optimization opportunities
   • Check for unused or underutilized resources
   • Consider reserved instances for predictable workloads
   • Enable Azure Advisor for personalized recommendations
   • Review storage tiers and lifecycle policies

EOF
}

# Generate CSV report
generate_csv_report() {
    local aggregated_data="$1"
    
    echo "SubscriptionId,ResourceGroup,ServiceName,MeterCategory,Cost" > "$CSV_FILE"
    
    echo "$aggregated_data" | jq -r '
        .[] |
        .resourceGroup as $rg |
        .subscriptionId as $sub |
        .services[] |
        [$sub, $rg, .serviceName, .meterCategory, (.cost | tostring)] |
        @csv
    ' >> "$CSV_FILE"
    
    log "CSV report saved to: $CSV_FILE"
}

# Generate JSON report
generate_json_report() {
    local aggregated_data="$1"
    local start_date="$2"
    local end_date="$3"
    local total_cost="$4"
    
    jq -n \
        --arg startDate "$start_date" \
        --arg endDate "$end_date" \
        --arg totalCost "$total_cost" \
        --argjson data "$aggregated_data" \
        '{
            reportPeriod: {
                startDate: $startDate,
                endDate: $endDate
            },
            totalCost: ($totalCost | tonumber),
            currency: "USD",
            resourceGroups: $data
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
    
    log "Processing subscription: $subscription_id"
    
    # Get subscription name
    local sub_name=$(get_subscription_name "$subscription_id")
    
    # Get cost data from Azure
    local cost_data=$(get_cost_data "$subscription_id" "$start_date" "$end_date" "$RESOURCE_GROUPS")
    
    # Check if we got valid data
    local row_count=$(echo "$cost_data" | jq '.properties.rows // [] | length' 2>/dev/null || echo "0")
    if [[ $row_count -eq 0 ]]; then
        log "⚠️  Subscription $subscription_id: No cost data returned"
        log "   Possible reasons: No costs, insufficient permissions, or data not yet available"
        return 1
    fi
    
    log "✅ Subscription $subscription_id ($sub_name): Retrieved $row_count cost records"
    
    # Parse and aggregate data
    local aggregated_data=$(parse_cost_data "$cost_data")
    
    # Add subscription ID and name to each resource group entry
    aggregated_data=$(echo "$aggregated_data" | jq --arg sub "$subscription_id" --arg subName "$sub_name" 'map(. + {subscriptionId: $sub, subscriptionName: $subName})')
    
    echo "$aggregated_data"
}

# Main function
main() {
    log "Starting Azure Cost Report Generation"
    
    if [[ -z "$SUBSCRIPTION_ID" ]]; then
        echo "Error: AZURE_SUBSCRIPTION_ID environment variable not set"
        exit 1
    fi
    
    log "Target subscription(s): $SUBSCRIPTION_ID"
    log "Target resource groups: $RESOURCE_GROUPS"
    
    # Get date range
    local dates=$(get_date_range)
    IFS='|' read -r start_date end_date <<< "$dates"
    
    log "Report period: $start_date to $end_date (30 days)"
    
    # Process multiple subscriptions
    local all_aggregated_data='[]'
    local successful_subs=0
    local failed_subs=0
    local failed_sub_ids=""
    
    IFS=',' read -ra SUB_ARRAY <<< "$SUBSCRIPTION_ID"
    for sub_id in "${SUB_ARRAY[@]}"; do
        sub_id=$(echo "$sub_id" | xargs)  # trim whitespace
        
        local sub_data=$(process_subscription "$sub_id" "$start_date" "$end_date")
        if [[ $? -eq 0 && -n "$sub_data" && "$sub_data" != "[]" ]]; then
            # Merge this subscription's data with the overall data
            all_aggregated_data=$(echo "$all_aggregated_data" | jq --argjson new "$sub_data" '. + $new')
            ((successful_subs++))
        else
            ((failed_subs++))
            failed_sub_ids="${failed_sub_ids}${sub_id}, "
        fi
    done
    
    # Re-sort all data by total cost
    all_aggregated_data=$(echo "$all_aggregated_data" | jq 'sort_by(-.totalCost)')
    
    log "Successfully processed $successful_subs subscription(s)"
    if [[ $failed_subs -gt 0 ]]; then
        failed_sub_ids=${failed_sub_ids%, }  # Remove trailing comma
        log "⚠️  Failed to retrieve cost data from $failed_subs subscription(s): $failed_sub_ids"
    fi
    
    # Check if we have any data at all
    local total_rg_count=$(echo "$all_aggregated_data" | jq 'length')
    if [[ $total_rg_count -eq 0 ]]; then
        log "❌ No cost data available from any subscription"
        
        cat > "$REPORT_FILE" << EOF
╔══════════════════════════════════════════════════════════════════════╗
║          AZURE COST REPORT - LAST 30 DAYS                           ║
║          Period: $start_date to $end_date                      ║
╚══════════════════════════════════════════════════════════════════════╝

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
        exit 0
    fi
    
    # Calculate total cost (rounded to 2 decimal places)
    local total_cost=$(echo "$all_aggregated_data" | jq '[.[].totalCost] | add // 0 | (. * 100 | round) / 100')
    
    log "Total cost across all subscriptions: \$$total_cost"
    
    # Generate reports
    if [[ "$OUTPUT_FORMAT" == "csv" || "$OUTPUT_FORMAT" == "all" ]]; then
        generate_csv_report "$all_aggregated_data"
    fi
    
    if [[ "$OUTPUT_FORMAT" == "json" || "$OUTPUT_FORMAT" == "all" ]]; then
        generate_json_report "$all_aggregated_data" "$start_date" "$end_date" "$total_cost"
    fi
    
    if [[ "$OUTPUT_FORMAT" == "table" || "$OUTPUT_FORMAT" == "all" ]]; then
        generate_table_report "$all_aggregated_data" "$start_date" "$end_date" "$total_cost"
        log "Report saved to: $REPORT_FILE"
        echo ""
        cat "$REPORT_FILE"
    fi
    
    log "✅ Cost report generation complete!"
    log "   Successful subscriptions: $successful_subs"
    if [[ $failed_subs -gt 0 ]]; then
        log "   ⚠️  Failed subscriptions: $failed_subs ($failed_sub_ids)"
    fi
}

main "$@"

