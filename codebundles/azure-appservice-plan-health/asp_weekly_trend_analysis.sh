#!/bin/bash

# Azure App Service Plan Weekly Trend Analysis
# Analyzes week-over-week utilization trends for plan-level and app-level metrics
# Detects growth patterns, declining performance, and error rate trends

set -euo pipefail

# Environment variables
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-}"
AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
LOOKBACK_WEEKS="${LOOKBACK_WEEKS:-4}"  # Default: 4 weeks of data

# Output files
REPORT_FILE="asp_weekly_trend_report.txt"
ISSUES_FILE="asp_weekly_trend_issues.json"
TREND_DATA_FILE="asp_weekly_trend_data.json"

# Thresholds for trend detection
UTILIZATION_GROWTH_THRESHOLD=15    # Alert if utilization grew >15% week-over-week
UTILIZATION_HIGH_THRESHOLD=80      # Alert if average utilization >80%
ERROR_RATE_THRESHOLD=5             # Alert if error rate >5%
RESPONSE_TIME_GROWTH_THRESHOLD=25  # Alert if response time grew >25%

# Logging
log() { echo "📊 [$(date '+%H:%M:%S')] $*" >&2; }
report() { echo "$*" >> "$REPORT_FILE"; }
hr() { echo "────────────────────────────────────────────────────────────────────────────────" >> "$REPORT_FILE"; }

# Initialize outputs
> "$REPORT_FILE"
echo '[]' > "$ISSUES_FILE"
echo '[]' > "$TREND_DATA_FILE"

# Set subscription
if [[ -z "$AZURE_SUBSCRIPTION_ID" ]]; then
    AZURE_SUBSCRIPTION_ID=$(az account show --query "id" -o tsv 2>/dev/null)
fi
az account set --subscription "$AZURE_SUBSCRIPTION_ID" 2>/dev/null || true

log "Starting App Service Plan Weekly Trend Analysis"
log "Resource Group: $AZURE_RESOURCE_GROUP"
log "Lookback: $LOOKBACK_WEEKS weeks"

report "╔═══════════════════════════════════════════════════════════════════════════════╗"
report "║   APP SERVICE PLAN WEEKLY TREND ANALYSIS                                      ║"
report "╚═══════════════════════════════════════════════════════════════════════════════╝"
report ""
report "Resource Group: $AZURE_RESOURCE_GROUP"
report "Analysis Period: Last $LOOKBACK_WEEKS weeks"
report "Generated: $(date '+%Y-%m-%d %H:%M:%S UTC')"
report ""

# Get all App Service Plans in the resource group
log "Fetching App Service Plans..."
plans=$(az appservice plan list \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --query "[].{id:id, name:name, sku:sku.name, tier:sku.tier, capacity:sku.capacity, location:location, kind:kind}" \
    -o json 2>/dev/null || echo '[]')

plan_count=$(echo "$plans" | jq 'length')
log "Found $plan_count App Service Plan(s)"

if [[ "$plan_count" -eq 0 ]]; then
    report "No App Service Plans found in resource group $AZURE_RESOURCE_GROUP"
    exit 0
fi

# Collect all issues
issues_json="[]"

# Process each plan
echo "$plans" | jq -c '.[]' | while read -r plan; do
    plan_id=$(echo "$plan" | jq -r '.id')
    plan_name=$(echo "$plan" | jq -r '.name')
    plan_sku=$(echo "$plan" | jq -r '.sku')
    plan_tier=$(echo "$plan" | jq -r '.tier')
    plan_capacity=$(echo "$plan" | jq -r '.capacity')
    
    log "Analyzing plan: $plan_name ($plan_tier/$plan_sku)"
    
    report ""
    hr
    report "PLAN: $plan_name"
    report "SKU: $plan_tier / $plan_sku | Capacity: $plan_capacity instances"
    hr
    report ""
    
    # Calculate date ranges for each week
    end_date=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Collect weekly metrics
    weekly_cpu_data="[]"
    weekly_mem_data="[]"
    weekly_requests_data="[]"
    weekly_errors_data="[]"
    
    for week_num in $(seq 0 $((LOOKBACK_WEEKS - 1))); do
        week_end=$(date -u -d "$((week_num * 7)) days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-$((week_num * 7))d +"%Y-%m-%dT%H:%M:%SZ")
        week_start=$(date -u -d "$((week_num * 7 + 7)) days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-$((week_num * 7 + 7))d +"%Y-%m-%dT%H:%M:%SZ")
        
        week_label="Week -$week_num"
        [[ $week_num -eq 0 ]] && week_label="Current Week"
        
        log "  Fetching metrics for $week_label ($week_start to $week_end)..."
        
        # Get CPU metrics for the week
        cpu_metrics=$(az monitor metrics list \
            --resource "$plan_id" \
            --metric "CpuPercentage" \
            --start-time "$week_start" \
            --end-time "$week_end" \
            --interval PT1H \
            --aggregation Average Maximum \
            -o json 2>/dev/null || echo '{}')
        
        cpu_avg=$(echo "$cpu_metrics" | jq -r '[.value[0].timeseries[0].data[]? | select(.average != null) | .average] | if length > 0 then (add / length) else 0 end' 2>/dev/null || echo "0")
        cpu_max=$(echo "$cpu_metrics" | jq -r '[.value[0].timeseries[0].data[]? | select(.maximum != null) | .maximum] | max // 0' 2>/dev/null || echo "0")
        
        # Get Memory metrics for the week
        mem_metrics=$(az monitor metrics list \
            --resource "$plan_id" \
            --metric "MemoryPercentage" \
            --start-time "$week_start" \
            --end-time "$week_end" \
            --interval PT1H \
            --aggregation Average Maximum \
            -o json 2>/dev/null || echo '{}')
        
        mem_avg=$(echo "$mem_metrics" | jq -r '[.value[0].timeseries[0].data[]? | select(.average != null) | .average] | if length > 0 then (add / length) else 0 end' 2>/dev/null || echo "0")
        mem_max=$(echo "$mem_metrics" | jq -r '[.value[0].timeseries[0].data[]? | select(.maximum != null) | .maximum] | max // 0' 2>/dev/null || echo "0")
        
        # Store weekly data
        weekly_cpu_data=$(echo "$weekly_cpu_data" | jq --arg week "$week_label" --argjson avg "$cpu_avg" --argjson max "$cpu_max" \
            '. + [{"week": $week, "avg": $avg, "max": $max}]')
        weekly_mem_data=$(echo "$weekly_mem_data" | jq --arg week "$week_label" --argjson avg "$mem_avg" --argjson max "$mem_max" \
            '. + [{"week": $week, "avg": $avg, "max": $max}]')
    done
    
    # Print weekly CPU trend
    report "CPU Utilization Trend:"
    report "┌─────────────────┬────────────┬────────────┐"
    report "│ Week            │ Avg CPU %  │ Max CPU %  │"
    report "├─────────────────┼────────────┼────────────┤"
    echo "$weekly_cpu_data" | jq -r '.[] | "│ \(.week | . + " " * (15 - length)) │ \(.avg | tostring | .[0:8] | . + " " * (10 - length)) │ \(.max | tostring | .[0:8] | . + " " * (10 - length)) │"' >> "$REPORT_FILE"
    report "└─────────────────┴────────────┴────────────┘"
    report ""
    
    # Print weekly Memory trend
    report "Memory Utilization Trend:"
    report "┌─────────────────┬────────────┬────────────┐"
    report "│ Week            │ Avg Mem %  │ Max Mem %  │"
    report "├─────────────────┼────────────┼────────────┤"
    echo "$weekly_mem_data" | jq -r '.[] | "│ \(.week | . + " " * (15 - length)) │ \(.avg | tostring | .[0:8] | . + " " * (10 - length)) │ \(.max | tostring | .[0:8] | . + " " * (10 - length)) │"' >> "$REPORT_FILE"
    report "└─────────────────┴────────────┴────────────┘"
    report ""
    
    # Calculate trends
    current_cpu=$(echo "$weekly_cpu_data" | jq '.[0].avg // 0')
    prev_cpu=$(echo "$weekly_cpu_data" | jq '.[1].avg // 0')
    current_mem=$(echo "$weekly_mem_data" | jq '.[0].avg // 0')
    prev_mem=$(echo "$weekly_mem_data" | jq '.[1].avg // 0')
    
    # Calculate growth percentages (handle division by zero)
    if (( $(echo "$prev_cpu > 0" | bc -l 2>/dev/null || echo "0") )); then
        cpu_growth=$(echo "scale=2; (($current_cpu - $prev_cpu) / $prev_cpu) * 100" | bc -l 2>/dev/null || echo "0")
    else
        cpu_growth=0
    fi
    
    if (( $(echo "$prev_mem > 0" | bc -l 2>/dev/null || echo "0") )); then
        mem_growth=$(echo "scale=2; (($current_mem - $prev_mem) / $prev_mem) * 100" | bc -l 2>/dev/null || echo "0")
    else
        mem_growth=0
    fi
    
    # Determine trend direction
    if (( $(echo "$cpu_growth > 5" | bc -l 2>/dev/null || echo "0") )); then
        cpu_trend="📈 INCREASING (+${cpu_growth}%)"
    elif (( $(echo "$cpu_growth < -5" | bc -l 2>/dev/null || echo "0") )); then
        cpu_trend="📉 DECREASING (${cpu_growth}%)"
    else
        cpu_trend="➡️ STABLE"
    fi
    
    if (( $(echo "$mem_growth > 5" | bc -l 2>/dev/null || echo "0") )); then
        mem_trend="📈 INCREASING (+${mem_growth}%)"
    elif (( $(echo "$mem_growth < -5" | bc -l 2>/dev/null || echo "0") )); then
        mem_trend="📉 DECREASING (${mem_growth}%)"
    else
        mem_trend="➡️ STABLE"
    fi
    
    report "Trend Analysis:"
    report "  CPU Trend: $cpu_trend"
    report "  Memory Trend: $mem_trend"
    report ""
    
    # Get apps in this plan and collect app-level metrics
    log "  Fetching apps in plan..."
    apps=$(az webapp list \
        --query "[?appServicePlanId=='$plan_id'].{id:id, name:name, state:state, resourceGroup:resourceGroup}" \
        -o json 2>/dev/null || echo '[]')
    
    app_count=$(echo "$apps" | jq 'length')
    report "Apps in Plan: $app_count"
    
    if [[ "$app_count" -gt 0 ]]; then
        report ""
        report "App-Level Metrics (Last 7 Days):"
        report "┌──────────────────────────┬────────────┬────────────┬────────────┬────────────────┐"
        report "│ App Name                 │ Requests   │ Http 4xx   │ Http 5xx   │ Avg Resp (ms)  │"
        report "├──────────────────────────┼────────────┼────────────┼────────────┼────────────────┤"
        
        # Collect app metrics
        total_requests=0
        total_4xx=0
        total_5xx=0
        total_resp_time=0
        app_with_metrics=0
        
        week_start=$(date -u -d "7 days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-7d +"%Y-%m-%dT%H:%M:%SZ")
        week_end=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        
        echo "$apps" | jq -c '.[]' | while read -r app; do
            app_id=$(echo "$app" | jq -r '.id')
            app_name=$(echo "$app" | jq -r '.name')
            
            # Get request count
            requests=$(az monitor metrics list \
                --resource "$app_id" \
                --metric "Requests" \
                --start-time "$week_start" \
                --end-time "$week_end" \
                --interval PT1H \
                --aggregation Total \
                -o json 2>/dev/null | jq '[.value[0].timeseries[0].data[]? | select(.total != null) | .total] | add // 0' || echo "0")
            
            # Get HTTP 4xx errors
            http4xx=$(az monitor metrics list \
                --resource "$app_id" \
                --metric "Http4xx" \
                --start-time "$week_start" \
                --end-time "$week_end" \
                --interval PT1H \
                --aggregation Total \
                -o json 2>/dev/null | jq '[.value[0].timeseries[0].data[]? | select(.total != null) | .total] | add // 0' || echo "0")
            
            # Get HTTP 5xx errors
            http5xx=$(az monitor metrics list \
                --resource "$app_id" \
                --metric "Http5xx" \
                --start-time "$week_start" \
                --end-time "$week_end" \
                --interval PT1H \
                --aggregation Total \
                -o json 2>/dev/null | jq '[.value[0].timeseries[0].data[]? | select(.total != null) | .total] | add // 0' || echo "0")
            
            # Get average response time
            resp_time=$(az monitor metrics list \
                --resource "$app_id" \
                --metric "AverageResponseTime" \
                --start-time "$week_start" \
                --end-time "$week_end" \
                --interval PT1H \
                --aggregation Average \
                -o json 2>/dev/null | jq '[.value[0].timeseries[0].data[]? | select(.average != null) | .average] | if length > 0 then (add / length * 1000) else 0 end' || echo "0")
            
            # Format app name (truncate if needed)
            app_display=$(printf "%-24s" "${app_name:0:24}")
            requests_fmt=$(printf "%10.0f" "$requests")
            h4xx_fmt=$(printf "%10.0f" "$http4xx")
            h5xx_fmt=$(printf "%10.0f" "$http5xx")
            resp_fmt=$(printf "%14.0f" "$resp_time")
            
            echo "│ $app_display │ $requests_fmt │ $h4xx_fmt │ $h5xx_fmt │ $resp_fmt │" >> "$REPORT_FILE"
        done
        
        report "└──────────────────────────┴────────────┴────────────┴────────────┴────────────────┘"
    fi
    
    report ""
    
    # Generate issues based on trends
    # Issue: High utilization growth
    if (( $(echo "${cpu_growth#-} > $UTILIZATION_GROWTH_THRESHOLD" | bc -l 2>/dev/null || echo "0") )) && (( $(echo "$cpu_growth > 0" | bc -l 2>/dev/null || echo "0") )); then
        issue_title="Rapid CPU Utilization Growth in App Service Plan \`$plan_name\` in \`$AZURE_RESOURCE_GROUP\`"
        issue_details="CPU utilization has grown ${cpu_growth}% week-over-week.

Current Week Avg: ${current_cpu}%
Previous Week Avg: ${prev_cpu}%
Growth Rate: +${cpu_growth}%

This growth pattern may indicate:
- Increasing traffic/load
- Application performance degradation
- Resource contention"
        issue_next_steps="1. Review application logs for performance issues
2. Consider scaling up the App Service Plan ($plan_tier/$plan_sku)
3. Enable autoscaling if not already configured
4. Review recent deployments for performance regressions
5. Monitor for continued growth trend"
        
        issues_json=$(echo "$issues_json" | jq \
            --arg title "$issue_title" \
            --arg details "$issue_details" \
            --arg next_steps "$issue_next_steps" \
            '. + [{"title": $title, "details": $details, "severity": 3, "next_step": $next_steps}]')
    fi
    
    # Issue: Sustained high utilization
    if (( $(echo "$current_cpu > $UTILIZATION_HIGH_THRESHOLD" | bc -l 2>/dev/null || echo "0") )); then
        issue_title="Sustained High CPU Utilization in App Service Plan \`$plan_name\` in \`$AZURE_RESOURCE_GROUP\`"
        issue_details="CPU utilization is consistently above ${UTILIZATION_HIGH_THRESHOLD}%.

Current Week Avg: ${current_cpu}%
Max Observed: $(echo "$weekly_cpu_data" | jq '.[0].max // 0')%

High sustained utilization may cause:
- Increased response times
- Request timeouts
- Poor user experience"
        issue_next_steps="1. Immediately review if scaling is needed
2. Check for runaway processes or memory leaks
3. Review application performance metrics
4. Consider vertical scaling (larger SKU) or horizontal scaling (more instances)
5. Implement request throttling if appropriate"
        
        issues_json=$(echo "$issues_json" | jq \
            --arg title "$issue_title" \
            --arg details "$issue_details" \
            --arg next_steps "$issue_next_steps" \
            '. + [{"title": $title, "details": $details, "severity": 2, "next_step": $next_steps}]')
    fi
    
    # Issue: Memory growth
    if (( $(echo "${mem_growth#-} > $UTILIZATION_GROWTH_THRESHOLD" | bc -l 2>/dev/null || echo "0") )) && (( $(echo "$mem_growth > 0" | bc -l 2>/dev/null || echo "0") )); then
        issue_title="Rapid Memory Utilization Growth in App Service Plan \`$plan_name\` in \`$AZURE_RESOURCE_GROUP\`"
        issue_details="Memory utilization has grown ${mem_growth}% week-over-week.

Current Week Avg: ${current_mem}%
Previous Week Avg: ${prev_mem}%
Growth Rate: +${mem_growth}%

This may indicate:
- Memory leak in application
- Increased caching without eviction
- Growing dataset in memory"
        issue_next_steps="1. Review application for memory leaks
2. Check garbage collection metrics
3. Review caching strategies
4. Consider scaling the plan if memory pressure continues
5. Enable memory profiling for the application"
        
        issues_json=$(echo "$issues_json" | jq \
            --arg title "$issue_title" \
            --arg details "$issue_details" \
            --arg next_steps "$issue_next_steps" \
            '. + [{"title": $title, "details": $details, "severity": 3, "next_step": $next_steps}]')
    fi
    
done

# Write final issues file
echo "$issues_json" > "$ISSUES_FILE"

# Summary
report ""
hr
report "ANALYSIS COMPLETE"
report "Generated: $(date '+%Y-%m-%d %H:%M:%S UTC')"
hr

# Print report to stdout
cat "$REPORT_FILE"

issue_count=$(echo "$issues_json" | jq 'length')
log "Analysis complete. Found $issue_count issue(s)."
