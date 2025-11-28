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

# Temp directory for large data processing (use current directory)
TEMP_DIR="${TEMP_DIR:-.}"

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

   RESOURCE GROUP                   SUBSCRIPTION                     COST      %
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
    
    # Use temp file to avoid "Argument list too long" error with large datasets
    local temp_data_file=$(mktemp "$TEMP_DIR/azure_cost_report_XXXXXX.json")
    echo "$aggregated_data" > "$temp_data_file"
    
    jq -n \
        --arg startDate "$start_date" \
        --arg endDate "$end_date" \
        --arg totalCost "$total_cost" \
        --slurpfile data "$temp_data_file" \
        '{
            reportPeriod: {
                startDate: $startDate,
                endDate: $endDate
            },
            totalCost: ($totalCost | tonumber),
            currency: "USD",
            resourceGroups: $data[0]
        }' > "$JSON_FILE"
    
    rm -f "$temp_data_file"
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
    
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "📋 Processing subscription: $subscription_id"
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Get subscription name
    log "   Retrieving subscription details..."
    local sub_name=$(get_subscription_name "$subscription_id")
    log "   ✓ Subscription name: $sub_name"
    
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
            log "   • All costs are $0 (free tier resources)"
            
            # Debug: Show first few properties
            local props_preview=$(echo "$cost_data" | jq -r '.properties | keys' 2>/dev/null)
            if [[ -n "$props_preview" && "$props_preview" != "null" ]]; then
                log "   ℹ️  API Response properties: $props_preview"
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
    log "   ✓ Aggregated costs across $rg_count resource group(s)"
    log ""
    
    echo "$aggregated_data"
}

# Main function
main() {
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║   Azure Cost Report Generation                                    ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    log "🚀 Starting cost report generation at $(date '+%Y-%m-%d %H:%M:%S')"
    log ""
    
    if [[ -z "$SUBSCRIPTION_IDS" ]]; then
        echo "❌ Error: AZURE_SUBSCRIPTION_IDS environment variable not set"
        exit 1
    fi
    
    local sub_count=$(echo "$SUBSCRIPTION_IDS" | tr ',' '\n' | wc -l)
    log "🎯 Target: $sub_count subscription(s)"
    log "📦 Resource groups: ${RESOURCE_GROUPS:-ALL}"
    log ""
    
    # Get date range
    local dates=$(get_date_range)
    IFS='|' read -r start_date end_date <<< "$dates"
    
    log "📅 Report period: $start_date to $end_date (30 days)"
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
        
        log "═══════════════════════════════════════════════════════════════"
        log "Processing subscription [$current_sub/$total_subs]"
        log "═══════════════════════════════════════════════════════════════"
        
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
        
        # Also output top 5 resource groups summary to stderr for easy parsing
        if [[ -f "$JSON_FILE" ]]; then
            echo "" >&2
            echo "💰 Top 5 Resource Groups by Cost:" >&2
            jq -r '.resourceGroups[:5] | .[] | "  • " + .resourceGroup + ": $" + (.totalCost * 100 | round / 100 | tostring)' "$JSON_FILE" 2>/dev/null | sed 's/^/  /' >&2 || true
        fi
    fi
    
    echo ""
    log "══════════════════════════════════════════════════════════════════"
    log "✅ Cost report generation complete!"
    log "══════════════════════════════════════════════════════════════════"
    log "   Finished at: $(date '+%Y-%m-%d %H:%M:%S')"
    log "   Successful subscriptions: $successful_subs/$total_subs"
    if [[ $failed_subs -gt 0 ]]; then
        failed_sub_ids=${failed_sub_ids%, }
        log "   ⚠️  Failed subscriptions: $failed_subs ($failed_sub_ids)"
    fi
    log "   Report file: $REPORT_FILE"
    log ""
}

main "$@"

