#!/bin/bash

# Function App Invocation Health Check Script
# This script checks the health and metrics of individual function invocations

set -e

# Source environment variables
source .env 2>/dev/null || true

# Default values
FUNCTION_APP_NAME=${FUNCTION_APP_NAME:-""}
AZ_RESOURCE_GROUP=${AZ_RESOURCE_GROUP:-""}
AZURE_RESOURCE_SUBSCRIPTION_ID=${AZURE_RESOURCE_SUBSCRIPTION_ID:-""}
TIME_PERIOD_MINUTES=${TIME_PERIOD_MINUTES:-30}
FUNCTION_ERROR_RATE_THRESHOLD=${FUNCTION_ERROR_RATE_THRESHOLD:-10}
FUNCTION_MEMORY_THRESHOLD=${FUNCTION_MEMORY_THRESHOLD:-512}
FUNCTION_DURATION_THRESHOLD=${FUNCTION_DURATION_THRESHOLD:-5000}

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

echo "🔍 Checking Function App Invocation Health"
echo "=========================================="
echo "Function App: $FUNCTION_APP_NAME"
echo "Resource Group: $AZ_RESOURCE_GROUP"
echo "Subscription: $AZURE_RESOURCE_SUBSCRIPTION_ID"
echo "Time Period: Last $TIME_PERIOD_MINUTES minutes"
echo "Thresholds:"
echo "  - Error Rate: ${FUNCTION_ERROR_RATE_THRESHOLD}%"
echo "  - Memory Usage: ${FUNCTION_MEMORY_THRESHOLD}MB"
echo "  - Duration: ${FUNCTION_DURATION_THRESHOLD}ms"
echo ""

# Get subscription name from environment variable
SUBSCRIPTION_NAME="${AZURE_SUBSCRIPTION_NAME:-Unknown}"

# Get the function app resource ID
FUNCTION_APP_ID=$(az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "id" -o tsv 2>/dev/null)
if [[ -z "$FUNCTION_APP_ID" ]]; then
    echo "❌ ERROR: Could not retrieve Function App ID for $FUNCTION_APP_NAME"
    exit 1
fi

# Get list of functions in the function app
echo "📋 Retrieving function list..."
FUNCTIONS=$(az functionapp function list --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "[].name" -o tsv 2>/dev/null)

if [[ -z "$FUNCTIONS" ]]; then
    echo "⚠️  WARNING: No functions found in Function App $FUNCTION_APP_NAME"
    echo "This could indicate:"
    echo "  - Functions are not deployed"
    echo "  - Function App is not properly configured"
    echo "  - Access permissions issues"
    echo ""
    echo "{}" > function_invocation_health.json
    echo "No functions found in Function App $FUNCTION_APP_NAME" > function_invocation_summary.txt
    exit 0
fi

echo "✅ Found $(echo "$FUNCTIONS" | wc -w) function(s):"
for func in $FUNCTIONS; do
    echo "  - $func"
done
echo ""

# Initialize issues array and tracking variables
ISSUES=()
SUMMARY_DATA=""
FUNCTIONS_WITH_NO_EXECUTIONS=()
FUNCTIONS_WITH_ERRORS=()
FUNCTIONS_WITH_THROTTLES=()
FUNCTIONS_WITH_HIGH_MEMORY=()
FUNCTIONS_WITH_SLOW_EXECUTION=()

# Calculate time range for metrics
END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
START_TIME=$(date -u -d "$TIME_PERIOD_MINUTES minutes ago" +"%Y-%m-%dT%H:%M:%SZ")

echo "⏰ Time range: $START_TIME to $END_TIME"
echo ""

echo "🔍 Checking Function App Level Metrics (Faster Approach)"
echo "======================================================="

# Get Function App level metrics instead of individual function metrics
# This is much faster and gives us overall health picture
echo "📊 Querying Function App level metrics..."

# Get overall execution count
TOTAL_EXECUTIONS=$(az monitor metrics list \
    --resource "$FUNCTION_APP_ID" \
    --metric "FunctionExecutionCount" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --interval PT5M \
    --query "data[0].timeseries[0].data[0].total" -o tsv 2>/dev/null || echo "0")

# Get overall execution units
TOTAL_EXECUTION_UNITS=$(az monitor metrics list \
    --resource "$FUNCTION_APP_ID" \
    --metric "FunctionExecutionUnits" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --interval PT5M \
    --query "data[0].timeseries[0].data[0].total" -o tsv 2>/dev/null || echo "0")

# Get overall errors
TOTAL_ERRORS=$(az monitor metrics list \
    --resource "$FUNCTION_APP_ID" \
    --metric "FunctionErrors" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --interval PT5M \
    --query "data[0].timeseries[0].data[0].total" -o tsv 2>/dev/null || echo "0")

# Get overall throttles
TOTAL_THROTTLES=$(az monitor metrics list \
    --resource "$FUNCTION_APP_ID" \
    --metric "FunctionThrottles" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --interval PT5M \
    --query "data[0].timeseries[0].data[0].total" -o tsv 2>/dev/null || echo "0")

# Get average duration
AVG_DURATION=$(az monitor metrics list \
    --resource "$FUNCTION_APP_ID" \
    --metric "FunctionExecutionDuration" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --interval PT5M \
    --query "data[0].timeseries[0].data[0].average" -o tsv 2>/dev/null || echo "0")

# Get average memory usage
AVG_MEMORY=$(az monitor metrics list \
    --resource "$FUNCTION_APP_ID" \
    --metric "FunctionMemoryUsage" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --interval PT5M \
    --query "data[0].timeseries[0].data[0].average" -o tsv 2>/dev/null || echo "0")

echo "✅ Function App level metrics retrieved"
echo ""

# Calculate overall error rate
OVERALL_ERROR_RATE=0
if [[ "$TOTAL_EXECUTIONS" != "0" && "$TOTAL_EXECUTIONS" != "null" ]]; then
    OVERALL_ERROR_RATE=$(echo "scale=2; $TOTAL_ERRORS * 100 / $TOTAL_EXECUTIONS" | bc -l 2>/dev/null || echo "0")
fi

# Create summary data
SUMMARY_DATA="Function App: $FUNCTION_APP_NAME\n"
SUMMARY_DATA+="Resource Group: $AZ_RESOURCE_GROUP\n"
SUMMARY_DATA+="Subscription: $SUBSCRIPTION_NAME\n"
SUMMARY_DATA+="Time Period: Last $TIME_PERIOD_MINUTES minutes\n"
SUMMARY_DATA+="\nOverall Metrics:\n"
SUMMARY_DATA+="- Total Executions: $TOTAL_EXECUTIONS\n"
SUMMARY_DATA+="- Total Execution Units: $TOTAL_EXECUTION_UNITS\n"
SUMMARY_DATA+="- Total Errors: $TOTAL_ERRORS\n"
SUMMARY_DATA+="- Total Throttles: $TOTAL_THROTTLES\n"
SUMMARY_DATA+="- Average Duration: ${AVG_DURATION}ms\n"
SUMMARY_DATA+="- Average Memory Usage: ${AVG_MEMORY}MB\n"
SUMMARY_DATA+="- Overall Error Rate: ${OVERALL_ERROR_RATE}%\n"

echo "📋 Creating Issues Based on Function App Level Metrics"
echo "====================================================="

# Create issues based on overall metrics
if [[ "$TOTAL_EXECUTIONS" == "0" || "$TOTAL_EXECUTIONS" == "null" ]]; then
    echo "⚠️  No function executions detected"
    FUNCTIONS_WITH_NO_EXECUTIONS+=("all functions")
    
    no_exec_details="Function App: $FUNCTION_APP_NAME\n"
    no_exec_details+="Resource Group: $AZ_RESOURCE_GROUP\n"
    no_exec_details+="Subscription: $SUBSCRIPTION_NAME\n"
    no_exec_details+="Time Period: Last $TIME_PERIOD_MINUTES minutes\n"
    no_exec_details+="\nIssue: No function executions detected\n"
    no_exec_details+="\nPossible Causes:\n"
    no_exec_details+="- Functions are not triggered by any events\n"
    no_exec_details+="- Function triggers are not configured properly\n"
    no_exec_details+="- Functions are disabled or not deployed\n"
    no_exec_details+="- No events are being sent to trigger functions\n"
    no_exec_details+="\nNext Steps:\n"
    no_exec_details+="1. Review function trigger configurations\n"
    no_exec_details+="2. Check if functions are properly deployed\n"
    no_exec_details+="3. Verify that events are being sent to trigger functions\n"
    
    # Escape for JSON
    ESCAPED_NO_EXEC_DETAILS=$(echo "$no_exec_details" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    ESCAPED_FUNCTION_APP_NAME_NO_EXEC=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g')
    ESCAPED_SUBSCRIPTION_NAME_NO_EXEC=$(echo "$SUBSCRIPTION_NAME" | sed 's/"/\\"/g')
    
    ISSUES+=("{\"title\":\"Function App \`$ESCAPED_FUNCTION_APP_NAME_NO_EXEC\` in subscription \`$ESCAPED_SUBSCRIPTION_NAME_NO_EXEC\` has no executions in last $TIME_PERIOD_MINUTES minutes\",\"severity\":3,\"next_step\":\"Check function triggers and configuration\",\"details\":\"$ESCAPED_NO_EXEC_DETAILS\"}")
    
    echo "  ✅ Created issue for no executions (Severity 3)"
fi

# Check for high error rate
if [[ "$TOTAL_ERRORS" != "0" && "$TOTAL_ERRORS" != "null" ]]; then
    if (( $(echo "$OVERALL_ERROR_RATE > $FUNCTION_ERROR_RATE_THRESHOLD" | bc -l) )); then
        echo "⚠️  High error rate detected: ${OVERALL_ERROR_RATE}%"
        FUNCTIONS_WITH_ERRORS+=("all functions")
        
        error_details="Function App: $FUNCTION_APP_NAME\n"
        error_details+="Resource Group: $AZ_RESOURCE_GROUP\n"
        error_details+="Subscription: $SUBSCRIPTION_NAME\n"
        error_details+="Time Period: Last $TIME_PERIOD_MINUTES minutes\n"
        error_details+="\nIssue: High function error rate\n"
        error_details+="- Total Executions: $TOTAL_EXECUTIONS\n"
        error_details+="- Total Errors: $TOTAL_ERRORS\n"
        error_details+="- Error Rate: ${OVERALL_ERROR_RATE}% (threshold: ${FUNCTION_ERROR_RATE_THRESHOLD}%)\n"
        error_details+="\nPossible Causes:\n"
        error_details+="- Code bugs or exceptions in functions\n"
        error_details+="- Configuration issues\n"
        error_details+="- Resource constraints (memory, CPU)\n"
        error_details+="- External service dependencies failing\n"
        error_details+="\nNext Steps:\n"
        error_details+="1. Review function logs for error details\n"
        error_details+="2. Check function code for bugs\n"
        error_details+="3. Verify external dependencies\n"
        error_details+="4. Monitor resource usage\n"
        
        # Escape for JSON
        ESCAPED_ERROR_DETAILS=$(echo "$error_details" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
        ESCAPED_FUNCTION_APP_NAME_ERROR=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g')
        ESCAPED_SUBSCRIPTION_NAME_ERROR=$(echo "$SUBSCRIPTION_NAME" | sed 's/"/\\"/g')
        
        ISSUES+=("{\"title\":\"Function App \`$ESCAPED_FUNCTION_APP_NAME_ERROR\` in subscription \`$ESCAPED_SUBSCRIPTION_NAME_ERROR\` has high error rate of ${OVERALL_ERROR_RATE}%\",\"severity\":1,\"next_step\":\"Investigate function errors and logs\",\"details\":\"$ESCAPED_ERROR_DETAILS\"}")
        
        echo "  ✅ Created issue for high error rate (Severity 1)"
    fi
fi

# Check for throttles
if [[ "$TOTAL_THROTTLES" != "0" && "$TOTAL_THROTTLES" != "null" ]]; then
    echo "⚠️  Function throttles detected: $TOTAL_THROTTLES"
    FUNCTIONS_WITH_THROTTLES+=("all functions")
    
    throttle_details="Function App: $FUNCTION_APP_NAME\n"
    throttle_details+="Resource Group: $AZ_RESOURCE_GROUP\n"
    throttle_details+="Subscription: $SUBSCRIPTION_NAME\n"
    throttle_details+="Time Period: Last $TIME_PERIOD_MINUTES minutes\n"
    throttle_details+="\nIssue: Function throttling detected\n"
    throttle_details+="- Total Throttles: $TOTAL_THROTTLES\n"
    throttle_details+="\nPossible Causes:\n"
    throttle_details+="- Consumption plan limits exceeded\n"
    throttle_details+="- High concurrent execution count\n"
    throttle_details+="- Resource constraints\n"
    throttle_details+="\nNext Steps:\n"
    throttle_details+="1. Consider upgrading to a higher tier plan\n"
    throttle_details+="2. Implement retry logic with exponential backoff\n"
    throttle_details+="3. Optimize function execution patterns\n"
    
    # Escape for JSON
    ESCAPED_THROTTLE_DETAILS=$(echo "$throttle_details" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    ESCAPED_FUNCTION_APP_NAME_THROTTLE=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g')
    ESCAPED_SUBSCRIPTION_NAME_THROTTLE=$(echo "$SUBSCRIPTION_NAME" | sed 's/"/\\"/g')
    
    ISSUES+=("{\"title\":\"Function App \`$ESCAPED_FUNCTION_APP_NAME_THROTTLE\` in subscription \`$ESCAPED_SUBSCRIPTION_NAME_THROTTLE\` is being throttled ($TOTAL_THROTTLES throttles)\",\"severity\":2,\"next_step\":\"Check consumption plan limits or scale up\",\"details\":\"$ESCAPED_THROTTLE_DETAILS\"}")
    
    echo "  ✅ Created issue for throttling (Severity 2)"
fi

# Check for high memory usage
if [[ "$AVG_MEMORY" != "0" && "$AVG_MEMORY" != "null" ]]; then
    if (( $(echo "$AVG_MEMORY > $FUNCTION_MEMORY_THRESHOLD" | bc -l) )); then
        echo "⚠️  High memory usage detected: ${AVG_MEMORY}MB"
        FUNCTIONS_WITH_HIGH_MEMORY+=("all functions")
        
        memory_details="Function App: $FUNCTION_APP_NAME\n"
        memory_details+="Resource Group: $AZ_RESOURCE_GROUP\n"
        memory_details+="Subscription: $SUBSCRIPTION_NAME\n"
        memory_details+="Time Period: Last $TIME_PERIOD_MINUTES minutes\n"
        memory_details+="\nIssue: High memory usage\n"
        memory_details+="- Average Memory Usage: ${AVG_MEMORY}MB (threshold: ${FUNCTION_MEMORY_THRESHOLD}MB)\n"
        memory_details+="\nPossible Causes:\n"
        memory_details+="- Memory leaks in function code\n"
        memory_details+="- Large data processing\n"
        memory_details+="- Inefficient memory usage patterns\n"
        memory_details+="\nNext Steps:\n"
        memory_details+="1. Review function code for memory leaks\n"
        memory_details+="2. Optimize data processing patterns\n"
        memory_details+="3. Consider increasing memory allocation\n"
        
        # Escape for JSON
        ESCAPED_MEMORY_DETAILS=$(echo "$memory_details" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
        ESCAPED_FUNCTION_APP_NAME_MEMORY=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g')
        ESCAPED_SUBSCRIPTION_NAME_MEMORY=$(echo "$SUBSCRIPTION_NAME" | sed 's/"/\\"/g')
        
        ISSUES+=("{\"title\":\"Function App \`$ESCAPED_FUNCTION_APP_NAME_MEMORY\` in subscription \`$ESCAPED_SUBSCRIPTION_NAME_MEMORY\` has high memory usage (${AVG_MEMORY}MB average)\",\"severity\":3,\"next_step\":\"Review function memory usage and optimization\",\"details\":\"$ESCAPED_MEMORY_DETAILS\"}")
        
        echo "  ✅ Created issue for high memory usage (Severity 3)"
    fi
fi

# Check for slow execution
if [[ "$AVG_DURATION" != "0" && "$AVG_DURATION" != "null" ]]; then
    if (( $(echo "$AVG_DURATION > $FUNCTION_DURATION_THRESHOLD" | bc -l) )); then
        echo "⚠️  Slow execution detected: ${AVG_DURATION}ms average"
        FUNCTIONS_WITH_SLOW_EXECUTION+=("all functions")
        
        slow_details="Function App: $FUNCTION_APP_NAME\n"
        slow_details+="Resource Group: $AZ_RESOURCE_GROUP\n"
        slow_details+="Subscription: $SUBSCRIPTION_NAME\n"
        slow_details+="Time Period: Last $TIME_PERIOD_MINUTES minutes\n"
        slow_details+="\nIssue: Slow function execution\n"
        slow_details+="- Average Duration: ${AVG_DURATION}ms (threshold: ${FUNCTION_DURATION_THRESHOLD}ms)\n"
        slow_details+="\nPossible Causes:\n"
        slow_details+="- Inefficient algorithms\n"
        slow_details+="- External service dependencies\n"
        slow_details+="- Resource constraints\n"
        slow_details+="- Cold starts\n"
        slow_details+="\nNext Steps:\n"
        slow_details+="1. Profile function performance\n"
        slow_details+="2. Optimize algorithms and data processing\n"
        slow_details+="3. Review external dependencies\n"
        slow_details+="4. Consider using premium plan for better performance\n"
        
        # Escape for JSON
        ESCAPED_SLOW_DETAILS=$(echo "$slow_details" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
        ESCAPED_FUNCTION_APP_NAME_SLOW=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g')
        ESCAPED_SUBSCRIPTION_NAME_SLOW=$(echo "$SUBSCRIPTION_NAME" | sed 's/"/\\"/g')
        
        ISSUES+=("{\"title\":\"Function App \`$ESCAPED_FUNCTION_APP_NAME_SLOW\` in subscription \`$ESCAPED_SUBSCRIPTION_NAME_SLOW\` has slow execution (${AVG_DURATION}ms average)\",\"severity\":3,\"next_step\":\"Review function performance and optimization\",\"details\":\"$ESCAPED_SLOW_DETAILS\"}")
        
        echo "  ✅ Created issue for slow execution (Severity 3)"
    fi
fi

# Create JSON output
echo ""
echo "📋 Creating JSON Output"
echo "======================"

JSON_OUTPUT='{"issues": ['
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    for i in "${!ISSUES[@]}"; do
        if [[ $i -gt 0 ]]; then
            JSON_OUTPUT+=","
        fi
        JSON_OUTPUT+="${ISSUES[$i]}"
    done
fi
JSON_OUTPUT+='], "summary": {'
JSON_OUTPUT+="\"total_functions\": $(echo "$FUNCTIONS" | wc -w),"
JSON_OUTPUT+="\"total_executions\": $TOTAL_EXECUTIONS,"
JSON_OUTPUT+="\"total_errors\": $TOTAL_ERRORS,"
JSON_OUTPUT+="\"total_throttles\": $TOTAL_THROTTLES,"
JSON_OUTPUT+="\"error_rate\": $OVERALL_ERROR_RATE,"
JSON_OUTPUT+="\"avg_duration\": $AVG_DURATION,"
JSON_OUTPUT+="\"avg_memory\": $AVG_MEMORY"
JSON_OUTPUT+="}}"

# Validate and save JSON
if command -v jq >/dev/null 2>&1; then
    if echo "$JSON_OUTPUT" | jq empty >/dev/null 2>&1; then
        echo "$JSON_OUTPUT" > function_invocation_health.json
        echo "✅ JSON validation passed"
    else
        echo "❌ JSON validation failed - generating fallback JSON"
        echo '{"issues":[],"summary":{"total_functions":0,"total_executions":0,"total_errors":0,"total_throttles":0,"error_rate":0}}' > function_invocation_health.json
    fi
else
    # If jq is not available, write the JSON anyway but log a warning
    echo "$JSON_OUTPUT" > function_invocation_health.json
    echo "⚠️  jq not available - JSON validation skipped"
fi

# Save summary
echo "$SUMMARY_DATA" > function_invocation_summary.txt

echo ""
echo "✅ Function Invocation Health Check Completed"
echo "============================================="
echo "📄 Summary saved to: function_invocation_summary.txt"
echo "📊 Issues saved to: function_invocation_health.json"
echo ""

echo "📋 Executive Summary"
echo "==================="
echo "Function App: $FUNCTION_APP_NAME"
echo "Resource Group: $AZ_RESOURCE_GROUP"
echo "Subscription: $SUBSCRIPTION_NAME"
echo "Time Period: Last $TIME_PERIOD_MINUTES minutes"
echo "Total Functions: $(echo "$FUNCTIONS" | wc -w)"
echo "Total Executions: $TOTAL_EXECUTIONS"
echo "Total Errors: $TOTAL_ERRORS"
echo "Total Throttles: $TOTAL_THROTTLES"
echo "Overall Error Rate: ${OVERALL_ERROR_RATE}%"
echo "Issues Found: ${#ISSUES[@]}"
echo ""

if [[ ${#ISSUES[@]} -eq 0 ]]; then
    echo "🎉 All functions are healthy!"
else
    echo "⚠️  Issues detected:"
    for i in "${!ISSUES[@]}"; do
        issue_title=$(echo "${ISSUES[$i]}" | jq -r '.title' 2>/dev/null || echo "Issue $((i+1))")
        echo "  $((i+1)). $issue_title"
    done
fi
echo ""

echo "📊 Detailed Function Metrics"
echo "============================"
echo "$SUMMARY_DATA" 