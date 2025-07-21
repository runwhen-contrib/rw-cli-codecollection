#!/bin/bash

# ENV VARIABLES:
#   FUNCTION_APP_NAME     - Azure Function App name
#   AZ_RESOURCE_GROUP     - Resource group for the Function App
#   TIME_PERIOD_MINUTES   - (Optional) How many minutes to look back for metrics (default: 60)
#   AZURE_RESOURCE_SUBSCRIPTION_ID - (Optional) Subscription ID (defaults to current subscription)

# USAGE:
#   1. Make sure you're logged into Azure CLI
#   2. Run the script; it will check if there's a valid plan ID. If so, it queries plan-level metrics like CPU%/Memory.
#      Otherwise, it falls back to function-level metrics (CpuTime / MemoryWorkingSet on the site itself).

set -e

# Use subscription ID from environment variable
subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
echo "Using subscription ID: $subscription"

# Get subscription name from environment variable
subscription_name="${AZURE_SUBSCRIPTION_NAME:-Unknown}"

# Set the subscription to the determined ID
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }

TIME_PERIOD_MINUTES="${TIME_PERIOD_MINUTES:-60}"
start_time=$(date -u -d "$TIME_PERIOD_MINUTES minutes ago" '+%Y-%m-%dT%H:%M:%SZ')
end_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

echo "Analyzing plan usage for Function App: $FUNCTION_APP_NAME"
echo "Resource Group: $AZ_RESOURCE_GROUP"
echo "Time Range: $start_time to $end_time"
echo ""

issues_json='{"issues": []}'
metrics_json='{"metrics": []}'

# 1. Retrieve the function app details
function_app_details=$(az functionapp show \
    --name "$FUNCTION_APP_NAME" \
    --resource-group "$AZ_RESOURCE_GROUP" \
    -o json 2>/dev/null)

if [[ -z "$function_app_details" || "$function_app_details" == "null" ]]; then
    echo "Error: Function App '$FUNCTION_APP_NAME' not found in resource group '$AZ_RESOURCE_GROUP'."
    exit 1
fi

app_state=$(echo "$function_app_details" | jq -r '.state')
plan_id=$(echo "$function_app_details" | jq -r '.serverFarmId // .appServicePlanId // empty')
kind=$(echo "$function_app_details" | jq -r '.kind // empty')

echo "Function App State: $app_state"
echo "Kind: $kind"
echo "Plan Resource ID: ${plan_id:-<none>}"
echo ""

# If function app is not running, note an issue (optional).
if [[ "$app_state" != "Running" ]]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\` Not Running" \
        --arg nextStep "Ensure Function App \`$FUNCTION_APP_NAME\` is started before analyzing usage." \
        --arg severity "2" \
        --arg details "State: $app_state for Function App '$FUNCTION_APP_NAME' in subscription '$subscription_name'" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity|tonumber), "details": $details}]'
    )
fi

########################################
# 2. Decide where to get metrics from
########################################
# If plan_id is non-empty, we assume it's a standard or premium plan resource.
# Otherwise, we fall back to function-level metrics on the site itself.

resource_to_query="$plan_id"
metrics_description="(App Service Plan)"

if [[ -z "$plan_id" ]]; then
    resource_to_query=$(echo "$function_app_details" | jq -r '.id')
    metrics_description="(Function App Resource)"
fi

echo "Querying metrics on: $resource_to_query"
echo "Metrics Source: $metrics_description"
echo ""

########################################
# 3. Define the metrics to retrieve
########################################
# For dedicated/premium plan-level queries, typical metrics:
#   - "CpuPercentage", "MemoryWorkingSet"
#
# If we're falling back to the function app resource, we can try:
#   - "CpuTime", "MemoryWorkingSet"
#   (some function apps will show these, others might not)
#
# Adjust these lists as needed.

if [[ -n "$plan_id" ]]; then
  # plan-level metrics
  declare -a metrics_list=( "CpuPercentage" "MemoryPercentage" )
else
  # function-level fallback
  declare -a metrics_list=( "CpuTime" "MemoryWorkingSet" )
fi

########################################
# 4. Retrieve metrics & parse
########################################
for metric in "${metrics_list[@]}"; do
    echo "Fetching metric: $metric"
    metric_data=$(az monitor metrics list \
        --resource "$resource_to_query" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --interval "PT1M" \
        --metrics "$metric" \
        --output json 2>/dev/null)

    if [[ -z "$metric_data" || $(echo "$metric_data" | jq '.value | length') -eq 0 ]]; then
        echo "No data found for metric: $metric"
        continue
    fi

    total=0
    count=0
    max=-1
    min=-1

    # Flatten timeseries
    mapfile -t data_points < <(echo "$metric_data" | jq -c '.value[].timeseries[].data[]')
    
    # Track threshold violations for aggregation
    cpu_violations=0
    memory_violations=0
    cpu_time_violations=0
    cpu_max_violation=0
    memory_max_violation=0
    cpu_time_max_violation=0
    
    for dp in "${data_points[@]}"; do
        # plan-level metrics often use .average
        # function-level "CpuTime" might use .total or .average
        val=$(echo "$dp" | jq -r '.average // .total // "0"')
        [[ "$val" == "null" ]] && continue

        total=$(echo "$total + $val" | bc -l)
        count=$((count + 1))
        if (( $(echo "$val > $max" | bc -l) )); then
            max=$val
        fi
        if [[ "$min" == "-1" || $(echo "$val < $min" | bc -l) -eq 1 ]]; then
            min=$val
        fi

        # Track threshold violations for aggregation
        if [[ "$metric" == "CpuPercentage" && $(echo "$val > 80" | bc -l) -eq 1 ]]; then
            cpu_violations=$((cpu_violations + 1))
            if (( $(echo "$val > $cpu_max_violation" | bc -l) )); then
                cpu_max_violation=$val
            fi
        fi

        if [[ "$metric" == "MemoryPercentage" && $(echo "$val > 80" | bc -l) -eq 1 ]]; then
            memory_violations=$((memory_violations + 1))
            if (( $(echo "$val > $memory_max_violation" | bc -l) )); then
                memory_max_violation=$val
            fi
        fi

        if [[ "$metric" == "CpuTime" && $(echo "$val > 100" | bc -l) -eq 1 ]]; then
            cpu_time_violations=$((cpu_time_violations + 1))
            if (( $(echo "$val > $cpu_time_max_violation" | bc -l) )); then
                cpu_time_max_violation=$val
            fi
        fi
    done

    # Create aggregated issues after processing all data points
    if [[ "$metric" == "CpuPercentage" && $cpu_violations -gt 0 ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "High CPU Usage for Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\`" \
            --arg nextStep "Investigate or scale your plan if CPU usage is persistently above 80% for Function App \`$FUNCTION_APP_NAME\`" \
            --arg severity "3" \
            --arg details "CPU exceeded 80% threshold in $cpu_violations out of $count data points. Max: ${cpu_max_violation}%, Average: $(echo "$total / $count" | bc -l)% for Function App '$FUNCTION_APP_NAME' in subscription '$subscription_name'" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity|tonumber), "details": $details}]'
        )
    fi

    if [[ "$metric" == "MemoryPercentage" && $memory_violations -gt 0 ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "High Memory Usage for Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\`" \
            --arg nextStep "Investigate or scale out your plan if memory usage is frequently above 80% for Function App \`$FUNCTION_APP_NAME\`" \
            --arg severity "3" \
            --arg details "Memory exceeded 80% threshold in $memory_violations out of $count data points. Max: ${memory_max_violation}%, Average: $(echo "$total / $count" | bc -l)% for Function App '$FUNCTION_APP_NAME' in subscription '$subscription_name'" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity|tonumber), "details": $details}]'
        )
    fi

    if [[ "$metric" == "CpuTime" && $cpu_time_violations -gt 0 ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "High CPU Time (Function-level) for Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\`" \
            --arg nextStep "Investigate function usage or optimize code if CPUTime is excessively high for Function App \`$FUNCTION_APP_NAME\`" \
            --arg severity "3" \
            --arg details "CpuTime exceeded 100 threshold in $cpu_time_violations out of $count data points. Max: ${cpu_time_max_violation}, Average: $(echo "$total / $count" | bc -l) for Function App '$FUNCTION_APP_NAME' in subscription '$subscription_name'" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity|tonumber), "details": $details}]'
        )
    fi

    # Summaries
    if (( count > 0 )); then
        avg=$(echo "$total / $count" | bc -l)
    else
        avg=0
        min=0
        max=0
    fi

    metrics_json=$(echo "$metrics_json" | jq \
        --arg name "$metric" \
        --argjson count "$count" \
        --argjson total "$total" \
        --argjson avg "$avg" \
        --argjson mx "$max" \
        --argjson mn "$min" \
        '.metrics += [{
            "metric": $name,
            "count": $count,
            "total": $total,
            "average": $avg,
            "max": $mx,
            "min": $mn
        }]'
    )
done

# 5. Output files
issues_file="function_app_plan_issues.json"
metrics_file="function_app_plan_metrics.json"
summary_file="function_app_plan_summary.txt"

echo "$issues_json"   > "$issues_file"
echo "$metrics_json"  > "$metrics_file"

issue_count=$(echo "$issues_json" | jq '.issues | length')

{
    echo "Function App Plan Usage Summary"
    echo "================================"
    echo "Function App:   $FUNCTION_APP_NAME"
    echo "Resource Group: $AZ_RESOURCE_GROUP"
    echo "Subscription:   $subscription_name"
    echo "Kind:           $kind"
    echo "Plan ID:        ${plan_id:-<none>}"
    echo "Time Range:     $start_time to $end_time"
    echo "Issues Count:   $issue_count"
    echo ""

    echo "Metrics Collected ($metrics_description):"
    echo "$metrics_json" | jq -r '.metrics[] | "  \(.metric): count=\(.count), avg=\(.average), min=\(.min), max=\(.max), total=\(.total)"'
    echo ""

    if (( issue_count > 0 )); then
        echo "Issues Detected:"
        echo "$issues_json" | jq -r '.issues[] | "Title: \(.title)\nSeverity: \(.severity)\nDetails: \(.details)\nNext Steps: \(.next_step)\n"'
    else
        echo "No issues found."
    fi
} > "$summary_file"

echo ""
echo "Results:"
echo "  Summary File: $summary_file"
echo "  Metrics File: $metrics_file"
echo "  Issues File:  $issues_file"
echo "Done."
