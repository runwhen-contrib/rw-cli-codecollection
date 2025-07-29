#!/bin/bash

# Function App Enhanced Invocation Logger
# This script provides detailed logging of every function invocation with success/failure tracking

set -e

# Source environment variables
source .env 2>/dev/null || true

# Default values
FUNCTION_APP_NAME=${FUNCTION_APP_NAME:-""}
AZ_RESOURCE_GROUP=${AZ_RESOURCE_GROUP:-""}
AZURE_RESOURCE_SUBSCRIPTION_ID=${AZURE_RESOURCE_SUBSCRIPTION_ID:-""}
TIME_PERIOD_MINUTES=${TIME_PERIOD_MINUTES:-30}

# Validation
if [[ -z "$FUNCTION_APP_NAME" ]]; then
    echo "ERROR: FUNCTION_APP_NAME is required"
    exit 1
fi

if [[ -z "$AZ_RESOURCE_GROUP" ]]; then
    echo "ERROR: AZ_RESOURCE_GROUP is required"
    exit 1
fi

if [[ -z "$AZURE_RESOURCE_SUBSCRIPTION_ID" ]]; then
    echo "ERROR: AZURE_RESOURCE_SUBSCRIPTION_ID is required"
    exit 1
fi

echo "📊 Enhanced Function Invocation Logging"
echo "======================================="
echo "Function App: $FUNCTION_APP_NAME"
echo "Resource Group: $AZ_RESOURCE_GROUP"
echo "Time Period: Last $TIME_PERIOD_MINUTES minutes"
echo ""

# Get the function app resource ID
FUNCTION_APP_ID=$(az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "id" -o tsv 2>/dev/null)
if [[ -z "$FUNCTION_APP_ID" ]]; then
    echo "❌ ERROR: Could not retrieve Function App ID for $FUNCTION_APP_NAME"
    exit 1
fi

# Get subscription name from environment variable
SUBSCRIPTION_NAME="${AZURE_SUBSCRIPTION_NAME:-Unknown}"

# Calculate time range
END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
START_TIME=$(date -u -d "$TIME_PERIOD_MINUTES minutes ago" +"%Y-%m-%dT%H:%M:%SZ")

# Get list of functions
FUNCTIONS=$(az functionapp function list --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "[].name" -o tsv 2>/dev/null)

if [[ -z "$FUNCTIONS" ]]; then
    echo "⚠️  No functions found in Function App $FUNCTION_APP_NAME"
    
    # Create issue_details format for no functions case
    details="Function App: $FUNCTION_APP_NAME\nResource Group: $AZ_RESOURCE_GROUP\nSubscription: $SUBSCRIPTION_NAME\nTime Period: Last $TIME_PERIOD_MINUTES minutes\n\nIssue: No functions found for invocation logging\n\nSummary:\nTotal Functions: 0\nTotal Invocations: 0\nIdle Functions: 0\n\nPossible Causes:\n- Function app \`$FUNCTION_APP_NAME\` is empty or newly created\n- Functions not deployed to \`$FUNCTION_APP_NAME\` in resource group \`$AZ_RESOURCE_GROUP\`\n- Function app \`$FUNCTION_APP_NAME\` is stopped or disabled\n- Deployment issues preventing function registration\n\nNext Steps:\n1. Check if \`$FUNCTION_APP_NAME\` in resource group \`$AZ_RESOURCE_GROUP\` is running\n2. Verify functions have been deployed to \`$FUNCTION_APP_NAME\`\n3. Review deployment logs for \`$FUNCTION_APP_NAME\`\n4. Check service endpoints and application configuration"
    
    ESCAPED_DETAILS=$(echo "$details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    ESCAPED_FUNCTION_APP_NAME=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g')
    ESCAPED_SUBSCRIPTION_NAME=$(echo "$SUBSCRIPTION_NAME" | sed 's/"/\\"/g')
    
    JSON_OUTPUT="{\"issues\": [{\"title\":\"Function App \`$ESCAPED_FUNCTION_APP_NAME\` in subscription \`$ESCAPED_SUBSCRIPTION_NAME\` has no functions for invocation logging\",\"severity\":4,\"next_step\":\"Check if \`$ESCAPED_FUNCTION_APP_NAME\` in resource group \`$AZ_RESOURCE_GROUP\` is running and verify functions have been deployed\",\"details\":\"$ESCAPED_DETAILS\"}]}"
    
    echo "$JSON_OUTPUT" > invocation_log.json
    exit 0
fi

echo "📋 Logging invocations for $(echo "$FUNCTIONS" | wc -w) function(s)"

# Initialize data structures
declare -A FUNCTION_DETAILS
declare -A SUCCESS_COUNTS
declare -A FAILURE_COUNTS
declare -A DURATION_PATTERNS
declare -A MEMORY_PATTERNS
declare -A AVG_DURATION
declare -A AVG_MEMORY

# Function to get detailed metrics with time series data - OPTIMIZED VERSION
get_batch_invocation_data() {
    echo "📊 Collecting metrics efficiently for all functions..."
    
    # OPTIMIZATION 1: Get all execution data in a single call
    echo "  Getting execution counts for all functions..."
    local execution_data=$(az monitor metrics list \
        --resource "$FUNCTION_APP_ID" \
        --metric "FunctionExecutionCount" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --interval PT5M \
        --query "data[0].timeseries[].{function: metadata.FunctionName, data: data[].total}" -o json 2>/dev/null || echo "[]")
    
    # OPTIMIZATION 2: Get all error data in a single call
    echo "  Getting error counts for all functions..."
    local error_data=$(az monitor metrics list \
        --resource "$FUNCTION_APP_ID" \
        --metric "FunctionErrors" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --interval PT5M \
        --query "data[0].timeseries[].{function: metadata.FunctionName, data: data[].total}" -o json 2>/dev/null || echo "[]")
    
    # OPTIMIZATION 3: Get all duration data in a single call
    echo "  Getting duration data for all functions..."
    local duration_data=$(az monitor metrics list \
        --resource "$FUNCTION_APP_ID" \
        --metric "FunctionExecutionDuration" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --interval PT5M \
        --query "data[0].timeseries[].{function: metadata.FunctionName, data: data[].average}" -o json 2>/dev/null || echo "[]")
    
    # OPTIMIZATION 4: Get all memory data in a single call
    echo "  Getting memory data for all functions..."
    local memory_data=$(az monitor metrics list \
        --resource "$FUNCTION_APP_ID" \
        --metric "MemoryWorkingSet" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --interval PT5M \
        --query "data[0].timeseries[].{function: metadata.FunctionName, data: data[].average}" -o json 2>/dev/null || echo "[]")
    
    echo "  Processing data efficiently..."
    
    # Process each function's data from the batch results
    for func in $FUNCTIONS; do
        echo "  📊 Processing data for $func..."
        
        # Extract execution data for this function
        local total_executions=$(echo "$execution_data" | jq -r ".[] | select(.function == \"$func\") | .data | map(select(. != null)) | add // 0")
        
        # Extract error data for this function  
        local total_errors=$(echo "$error_data" | jq -r ".[] | select(.function == \"$func\") | .data | map(select(. != null)) | add // 0")
        
        # Calculate successes
        local total_successes=$((total_executions - total_errors))
        if [[ "$total_successes" -lt 0 ]]; then
            total_successes=0
        fi
        
        SUCCESS_COUNTS["$func"]="$total_successes"
        FAILURE_COUNTS["$func"]="$total_errors"
        
        # Extract duration data for this function
        local duration_values=$(echo "$duration_data" | jq -r ".[] | select(.function == \"$func\") | .data | map(select(. != null))")
        local avg_duration=$(echo "$duration_values" | jq 'add / length // 0')
        local max_duration=$(echo "$duration_values" | jq 'max // 0')
        local min_duration=$(echo "$duration_values" | jq 'min // 0')
        
        # Store individual values for easy access
        AVG_DURATION["$func"]=$(printf "%.0f" "$avg_duration")
        
        # Keep formatted string for backwards compatibility
        DURATION_PATTERNS["$func"]=$(printf "avg:%.0f,max:%.0f,min:%.0f" "$avg_duration" "$max_duration" "$min_duration")
        
        # Extract memory data for this function
        local memory_values=$(echo "$memory_data" | jq -r ".[] | select(.function == \"$func\") | .data | map(select(. != null))")
        local avg_memory_bytes=$(echo "$memory_values" | jq 'add / length // 0')
        local avg_memory_mb=$(echo "scale=1; $avg_memory_bytes / 1048576" | bc -l 2>/dev/null || echo "0.0")
        
        # Store individual values for easy access
        AVG_MEMORY["$func"]=$(printf "%.1f" "$avg_memory_mb")
        MEMORY_PATTERNS["$func"]=$(printf "%.1f" "$avg_memory_mb")
        
        echo "    ✅ Successes: $total_successes, ❌ Failures: $total_errors"
        echo "    ⏱️  Duration - Avg: ${avg_duration}ms, Max: ${max_duration}ms, Min: ${min_duration}ms"
        echo "    💾 Memory - Avg: ${avg_memory_mb}MB"
    done
}

# Function to create detailed invocation summary
create_invocation_summary() {
    local function_name="$1"
    local successes="${SUCCESS_COUNTS["$function_name"]:-0}"
    local failures="${FAILURE_COUNTS["$function_name"]:-0}"
    local total=$((successes + failures))
    local success_rate="0.00"
    local failure_rate="0.00"
    
    if [[ "$total" -gt 0 ]]; then
        success_rate=$(echo "scale=2; $successes * 100 / $total" | bc -l 2>/dev/null || echo "0.00")
        failure_rate=$(echo "scale=2; $failures * 100 / $total" | bc -l 2>/dev/null || echo "0.00")
    fi
    
    # Determine invocation health status
    local health_status="Healthy"
    if [[ "$total" -eq 0 ]]; then
        health_status="Idle"
    elif [[ $(echo "$failure_rate > 10" | bc -l 2>/dev/null) -eq 1 ]]; then
        health_status="Unhealthy"
    elif [[ $(echo "$failure_rate > 5" | bc -l 2>/dev/null) -eq 1 ]]; then
        health_status="Warning"
    fi
    
    # Parse duration data
    local duration_data="${DURATION_PATTERNS["$function_name"]:-"avg:0,max:0,min:0"}"
    local avg_duration=$(echo "$duration_data" | cut -d',' -f1 | cut -d':' -f2)
    local max_duration=$(echo "$duration_data" | cut -d',' -f2 | cut -d':' -f2)
    local min_duration=$(echo "$duration_data" | cut -d',' -f3 | cut -d':' -f2)
    
    echo "
📊 Function: $function_name
   Status: $health_status
   Total Invocations: $total
   ✅ Successful: $successes (${success_rate}%)
   ❌ Failed: $failures (${failure_rate}%)
   ⏱️  Avg Duration: ${avg_duration}ms
   ⚡ Max Duration: ${max_duration}ms
   🚀 Min Duration: ${min_duration}ms"
}

# Log each function's invocations - OPTIMIZED VERSION
echo ""
echo "📊 Fast Invocation Analysis"
echo "============================"

TOTAL_INVOCATIONS=0
TOTAL_SUCCESSES=0
TOTAL_FAILURES=0

# OPTIMIZATION: Get all data in batch instead of per-function calls
get_batch_invocation_data

# Create summaries for each function
for func in $FUNCTIONS; do
    echo ""
    echo "🔍 Summary for function: $func"
    create_invocation_summary "$func"
    
    # Add to totals
    successes="${SUCCESS_COUNTS["$func"]:-0}"
    failures="${FAILURE_COUNTS["$func"]:-0}"
    TOTAL_SUCCESSES=$((TOTAL_SUCCESSES + successes))
    TOTAL_FAILURES=$((TOTAL_FAILURES + failures))
    TOTAL_INVOCATIONS=$((TOTAL_INVOCATIONS + successes + failures))
done

echo ""
echo "📋 Creating Issue Details Output"
echo "================================"

# Initialize issues array
ISSUES=()

# Create issue for overall health status
if [[ "$TOTAL_INVOCATIONS" -gt 0 ]]; then
    overall_success_rate=$(echo "scale=2; $TOTAL_SUCCESSES * 100 / $TOTAL_INVOCATIONS" | bc -l 2>/dev/null || echo "0.00")
    overall_failure_rate=$(echo "scale=2; $TOTAL_FAILURES * 100 / $TOTAL_INVOCATIONS" | bc -l 2>/dev/null || echo "0.00")
    
    # Determine severity based on error rate
    severity=4  # Info by default
    if [[ $(echo "$overall_failure_rate > 10" | bc -l 2>/dev/null) -eq 1 ]]; then
        severity=2  # Error
    elif [[ $(echo "$overall_failure_rate > 5" | bc -l 2>/dev/null) -eq 1 ]]; then
        severity=3  # Warning
    fi
    
    # Build details string
    details="Function App: $FUNCTION_APP_NAME\nResource Group: $AZ_RESOURCE_GROUP\nSubscription: $SUBSCRIPTION_NAME\nTime Period: Last $TIME_PERIOD_MINUTES minutes\n\nIssue: Function invocation health analysis\n\nPer-Function Details:"
    
    for func in $FUNCTIONS; do
        successes="${SUCCESS_COUNTS["$func"]:-0}"
        failures="${FAILURE_COUNTS["$func"]:-0}"
        total=$((successes + failures))
        
        if [[ "$total" -eq 0 ]]; then
            details="$details\n- $func: IDLE (0 invocations)"
        else
            success_rate=$(echo "scale=1; $successes * 100 / $total" | bc -l 2>/dev/null || echo "0.0")
            avg_duration="${AVG_DURATION["$func"]:-0}"
            avg_memory="${AVG_MEMORY["$func"]:-0.0}"
            details="$details\n- $func: $total invocations, ${success_rate}% success rate, ${avg_duration}ms avg duration, ${avg_memory}MB avg memory"
        fi
    done
    
    details="$details\n\nSummary:\nTotal Functions: $(echo "$FUNCTIONS" | wc -w)\nTotal Invocations: $TOTAL_INVOCATIONS\nSuccessful Invocations: $TOTAL_SUCCESSES\nFailed Invocations: $TOTAL_FAILURES\nOverall Success Rate: ${overall_success_rate}%\nOverall Failure Rate: ${overall_failure_rate}%\nHealthy Functions: $(for func in $FUNCTIONS; do if [[ $(echo "${SUCCESS_COUNTS["$func"]:-0} + ${FAILURE_COUNTS["$func"]:-0}" | bc) -gt 0 ]] && [[ $(echo "scale=2; ${FAILURE_COUNTS["$func"]:-0} * 100 / (${SUCCESS_COUNTS["$func"]:-0} + ${FAILURE_COUNTS["$func"]:-0} + 0.01)" | bc -l) < 5 ]]; then echo "1"; fi; done | wc -l)\nWarning Functions: $(for func in $FUNCTIONS; do if [[ $(echo "${SUCCESS_COUNTS["$func"]:-0} + ${FAILURE_COUNTS["$func"]:-0}" | bc) -gt 0 ]] && [[ $(echo "scale=2; ${FAILURE_COUNTS["$func"]:-0} * 100 / (${SUCCESS_COUNTS["$func"]:-0} + ${FAILURE_COUNTS["$func"]:-0} + 0.01)" | bc -l) > 5 ]] && [[ $(echo "scale=2; ${FAILURE_COUNTS["$func"]:-0} * 100 / (${SUCCESS_COUNTS["$func"]:-0} + ${FAILURE_COUNTS["$func"]:-0} + 0.01)" | bc -l) < 10 ]]; then echo "1"; fi; done | wc -l)\nUnhealthy Functions: $(for func in $FUNCTIONS; do if [[ $(echo "${SUCCESS_COUNTS["$func"]:-0} + ${FAILURE_COUNTS["$func"]:-0}" | bc) -gt 0 ]] && [[ $(echo "scale=2; ${FAILURE_COUNTS["$func"]:-0} * 100 / (${SUCCESS_COUNTS["$func"]:-0} + ${FAILURE_COUNTS["$func"]:-0} + 0.01)" | bc -l) > 10 ]]; then echo "1"; fi; done | wc -l)\nIdle Functions: $(for func in $FUNCTIONS; do if [[ $(echo "${SUCCESS_COUNTS["$func"]:-0} + ${FAILURE_COUNTS["$func"]:-0}" | bc) -eq 0 ]]; then echo "1"; fi; done | wc -l)"
    
    # Add insights and recommendations with specific entity data
    details="$details\n\nPossible Causes:\n- External API failures affecting \`$FUNCTION_APP_NAME\` functions\n- Code bugs in recent deployments to resource group \`$AZ_RESOURCE_GROUP\`\n- Resource constraints on \`$FUNCTION_APP_NAME\` compute instances\n- Cold starts impacting function performance\n- Network connectivity issues from \`$AZ_RESOURCE_GROUP\` to external services\n\nNext Steps:\n1. Check Application Insights logs for \`$FUNCTION_APP_NAME\` in resource group \`$AZ_RESOURCE_GROUP\`\n2. Review recent deployments to \`$FUNCTION_APP_NAME\`\n3. Verify application configuration for functions in \`$FUNCTION_APP_NAME\`\n4. Check service endpoints and network connectivity\n5. Review error message details in Application Insights"
    
    # Escape for JSON
    ESCAPED_DETAILS=$(echo "$details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    ESCAPED_FUNCTION_APP_NAME=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g')
    ESCAPED_SUBSCRIPTION_NAME=$(echo "$SUBSCRIPTION_NAME" | sed 's/"/\\"/g')
    
    # Identify failing functions for more specific next steps
    failing_functions=""
    for func in $FUNCTIONS; do
        failures="${FAILURE_COUNTS["$func"]:-0}"
        successes="${SUCCESS_COUNTS["$func"]:-0}"
        total=$((successes + failures))
        if [[ "$total" -gt 0 ]]; then
            failure_rate=$(echo "scale=1; $failures * 100 / $total" | bc -l 2>/dev/null || echo "0.0")
            if [[ $(echo "$failure_rate > 10" | bc -l 2>/dev/null) -eq 1 ]]; then
                if [[ -n "$failing_functions" ]]; then
                    failing_functions="$failing_functions, \`$func\`"
                else
                    failing_functions="\`$func\`"
                fi
            fi
        fi
    done

    # Create title based on health status
    if [[ $(echo "$overall_failure_rate > 10" | bc -l 2>/dev/null) -eq 1 ]]; then
        title="Function App \`$ESCAPED_FUNCTION_APP_NAME\` in subscription \`$ESCAPED_SUBSCRIPTION_NAME\` has high error rate (${overall_failure_rate}%)"
        if [[ -n "$failing_functions" ]]; then
            next_step="Check Application Insights logs for failing functions ($failing_functions) in \`$ESCAPED_FUNCTION_APP_NAME\` resource group \`$AZ_RESOURCE_GROUP\` and review recent deployments"
        else
            next_step="Check Application Insights logs for \`$ESCAPED_FUNCTION_APP_NAME\` in resource group \`$AZ_RESOURCE_GROUP\` and review recent deployments to identify root cause of failures"
        fi
    elif [[ $(echo "$overall_failure_rate > 5" | bc -l 2>/dev/null) -eq 1 ]]; then
        title="Function App \`$ESCAPED_FUNCTION_APP_NAME\` in subscription \`$ESCAPED_SUBSCRIPTION_NAME\` has elevated error rate (${overall_failure_rate}%)"
        if [[ -n "$failing_functions" ]]; then
            next_step="Review error message details for functions ($failing_functions) in Application Insights for \`$ESCAPED_FUNCTION_APP_NAME\` resource group \`$AZ_RESOURCE_GROUP\`"
        else
            next_step="Review error message details in Application Insights for \`$ESCAPED_FUNCTION_APP_NAME\` and verify application configuration in resource group \`$AZ_RESOURCE_GROUP\`"
        fi
    else
        title="Function App \`$ESCAPED_FUNCTION_APP_NAME\` in subscription \`$ESCAPED_SUBSCRIPTION_NAME\` invocation health summary"
        next_step="Check service endpoints for \`$ESCAPED_FUNCTION_APP_NAME\` and verify network connectivity from resource group \`$AZ_RESOURCE_GROUP\`"
    fi
    
    ISSUES+=("{\"title\":\"$title\",\"severity\":$severity,\"next_step\":\"$next_step\",\"details\":\"$ESCAPED_DETAILS\"}")
else
    # No invocations case
    details="Function App: $FUNCTION_APP_NAME\nResource Group: $AZ_RESOURCE_GROUP\nSubscription: $SUBSCRIPTION_NAME\nTime Period: Last $TIME_PERIOD_MINUTES minutes\n\nIssue: No function invocations detected\n\nSummary:\nTotal Functions: $(echo "$FUNCTIONS" | wc -w)\nTotal Invocations: 0\nIdle Functions: $(echo "$FUNCTIONS" | wc -w)\n\nPossible Causes:\n- Functions in \`$FUNCTION_APP_NAME\` not triggered during monitoring period\n- Function app \`$FUNCTION_APP_NAME\` is stopped or disabled\n- No active triggers configured for functions in resource group \`$AZ_RESOURCE_GROUP\`\n- Network connectivity issues preventing triggers\n\nNext Steps:\n1. Check if \`$FUNCTION_APP_NAME\` in resource group \`$AZ_RESOURCE_GROUP\` is running\n2. Verify trigger configurations for all functions\n3. Check service endpoints and network connectivity\n4. Review Application Insights for \`$FUNCTION_APP_NAME\` to identify trigger issues"
    
    ESCAPED_DETAILS=$(echo "$details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    ESCAPED_FUNCTION_APP_NAME=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g')
    ESCAPED_SUBSCRIPTION_NAME=$(echo "$SUBSCRIPTION_NAME" | sed 's/"/\\"/g')
    
    ISSUES+=("{\"title\":\"Function App \`$ESCAPED_FUNCTION_APP_NAME\` in subscription \`$ESCAPED_SUBSCRIPTION_NAME\` has no invocations in the last $TIME_PERIOD_MINUTES minutes\",\"severity\":4,\"next_step\":\"Check if \`$ESCAPED_FUNCTION_APP_NAME\` in resource group \`$AZ_RESOURCE_GROUP\` is running and verify trigger configurations for all functions\",\"details\":\"$ESCAPED_DETAILS\"}")
fi

# Create JSON output
JSON_OUTPUT='{"issues": ['
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    for i in "${!ISSUES[@]}"; do
        if [[ $i -gt 0 ]]; then
            JSON_OUTPUT+=","
        fi
        JSON_OUTPUT+="${ISSUES[$i]}"
    done
fi
JSON_OUTPUT+=']}'

# Validate and save JSON
echo "$JSON_OUTPUT" > invocation_log.json

if command -v jq >/dev/null 2>&1; then
    if jq empty invocation_log.json >/dev/null 2>&1; then
        echo "✅ Invocation log JSON validation passed"
        # Pretty print the JSON
        jq '.' invocation_log.json > temp.json && mv temp.json invocation_log.json
    else
        echo "❌ Invocation log JSON validation failed"
        exit 1
    fi
else
    echo "⚠️  jq not available - JSON validation skipped"
fi

echo ""
echo "✅ Enhanced Invocation Logging Completed"
echo "========================================"
echo "📄 Detailed invocation log saved to: invocation_log.json"
echo ""

echo "📊 Executive Summary"
echo "=================="
echo "Total Functions: $(echo "$FUNCTIONS" | wc -w)"
echo "Total Invocations: $TOTAL_INVOCATIONS"
echo "Successful Invocations: $TOTAL_SUCCESSES"
echo "Failed Invocations: $TOTAL_FAILURES"

if [[ "$TOTAL_INVOCATIONS" -gt 0 ]]; then
    overall_success_rate=$(echo "scale=2; $TOTAL_SUCCESSES * 100 / $TOTAL_INVOCATIONS" | bc -l 2>/dev/null || echo "0.00")
    overall_failure_rate=$(echo "scale=2; $TOTAL_FAILURES * 100 / $TOTAL_INVOCATIONS" | bc -l 2>/dev/null || echo "0.00")
    echo "Overall Success Rate: ${overall_success_rate}%"
    echo "Overall Failure Rate: ${overall_failure_rate}%"
else
    echo "Overall Success Rate: N/A (No invocations)"
    echo "Overall Failure Rate: N/A (No invocations)"
fi

echo ""
echo "🎯 Per-Function Summary"
echo "======================"
for func in $FUNCTIONS; do
    successes="${SUCCESS_COUNTS["$func"]:-0}"
    failures="${FAILURE_COUNTS["$func"]:-0}"
    total=$((successes + failures))
    
    if [[ "$total" -eq 0 ]]; then
        echo "  $func: IDLE (0 invocations)"
    else
        success_rate=$(echo "scale=1; $successes * 100 / $total" | bc -l 2>/dev/null || echo "0.0")
        echo "  $func: $total invocations, ${success_rate}% success rate"
    fi
done

echo ""
echo "📈 Ready for Analysis"
echo "===================="
echo "The invocation_log.json contains comprehensive invocation data including:"
echo "- Per-function success/failure counts and rates"
echo "- Performance metrics (duration patterns)"
echo "- Health status classification"
echo "- Aggregate insights and trends" 