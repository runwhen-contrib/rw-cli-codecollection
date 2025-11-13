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
    
    cat > "$REPORT_FILE" << EOF
╔══════════════════════════════════════════════════════════════════════╗
║          AZURE COST REPORT - LAST 30 DAYS                           ║
║          Period: $start_date to $end_date                      ║
╚══════════════════════════════════════════════════════════════════════╝

📊 TOTAL SUBSCRIPTION COST: \$$total_cost
$(printf '═%.0s' {1..72})

EOF
    
    # Generate report by resource group
    echo "$aggregated_data" | jq -r --arg sep "$(printf '─%.0s' {1..72})" '
        .[] | 
        "
🔹 RESOURCE GROUP: " + .resourceGroup + "
   Total Cost: $" + ((.totalCost * 100 | round) / 100 | tostring) + " (" + ((.totalCost / '$total_cost' * 100) | floor | tostring) + "% of subscription)
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
    
    echo "ResourceGroup,ServiceName,MeterCategory,Cost" > "$CSV_FILE"
    
    echo "$aggregated_data" | jq -r '
        .[] |
        .resourceGroup as $rg |
        .services[] |
        [$rg, .serviceName, .meterCategory, (.cost | tostring)] |
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

# Main function
main() {
    log "Starting Azure Cost Report Generation"
    
    if [[ -z "$SUBSCRIPTION_ID" ]]; then
        echo "Error: AZURE_SUBSCRIPTION_ID environment variable not set"
        exit 1
    fi
    
    log "Target subscription: $SUBSCRIPTION_ID"
    log "Target resource groups: $RESOURCE_GROUPS"
    
    # Get date range
    local dates=$(get_date_range)
    IFS='|' read -r start_date end_date <<< "$dates"
    
    log "Report period: $start_date to $end_date (30 days)"
    
    # Get cost data from Azure
    local cost_data=$(get_cost_data "$SUBSCRIPTION_ID" "$start_date" "$end_date" "$RESOURCE_GROUPS")
    
    # Check if we got valid data
    local row_count=$(echo "$cost_data" | jq '.properties.rows // [] | length' 2>/dev/null || echo "0")
    if [[ $row_count -eq 0 ]]; then
        log "⚠️  No cost data returned. This could mean:"
        log "   • No costs incurred in the period"
        log "   • Insufficient permissions to read cost data"
        log "   • Cost data not yet available (can take 24-48 hours)"
        
        cat > "$REPORT_FILE" << EOF
╔══════════════════════════════════════════════════════════════════════╗
║          AZURE COST REPORT - LAST 30 DAYS                           ║
║          Period: $start_date to $end_date                      ║
╚══════════════════════════════════════════════════════════════════════╝

⚠️  NO COST DATA AVAILABLE

Possible reasons:
• No costs incurred during this period
• Insufficient permissions (need Cost Management Reader or Contributor)
• Cost data not yet processed (can take 24-48 hours)
• Subscription ID incorrect

Please verify:
1. You have Cost Management Reader role
2. Costs have been incurred in the last 30 days
3. Cost data has been processed by Azure

EOF
        log "Report saved to: $REPORT_FILE"
        exit 0
    fi
    
    log "Retrieved $row_count cost records"
    
    # Parse and aggregate data
    log "Aggregating cost data..."
    local aggregated_data=$(parse_cost_data "$cost_data")
    
    # Calculate total cost (rounded to 2 decimal places)
    local total_cost=$(echo "$aggregated_data" | jq '[.[].totalCost] | add // 0 | (. * 100 | round) / 100')
    
    log "Total cost for period: \$$total_cost"
    
    # Generate reports
    if [[ "$OUTPUT_FORMAT" == "csv" || "$OUTPUT_FORMAT" == "all" ]]; then
        generate_csv_report "$aggregated_data"
    fi
    
    if [[ "$OUTPUT_FORMAT" == "json" || "$OUTPUT_FORMAT" == "all" ]]; then
        generate_json_report "$aggregated_data" "$start_date" "$end_date" "$total_cost"
    fi
    
    if [[ "$OUTPUT_FORMAT" == "table" || "$OUTPUT_FORMAT" == "all" ]]; then
        generate_table_report "$aggregated_data" "$start_date" "$end_date" "$total_cost"
        log "Report saved to: $REPORT_FILE"
        echo ""
        cat "$REPORT_FILE"
    fi
    
    log "✅ Cost report generation complete!"
}

main "$@"

