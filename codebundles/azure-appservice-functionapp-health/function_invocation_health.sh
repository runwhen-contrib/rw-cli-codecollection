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

echo "🔍 Checking Individual Function Metrics"
echo "======================================"

# Function to check individual function metrics
check_function_metrics() {
    local function_name=$1
    # Extract just the function name without the function app prefix
    local function_name_clean=$(echo "$function_name" | sed "s|^$FUNCTION_APP_NAME/||")
    local function_id="$FUNCTION_APP_ID/functions/$function_name_clean"
    
    echo "📊 Function: $function_name"
    
    # Get function execution count
    local execution_count=$(az monitor metrics list \
        --resource "$function_id" \
        --metric "FunctionExecutionCount" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --interval PT5M \
        --query "data[0].timeseries[0].data[0].total" -o tsv 2>/dev/null || echo "0")
    
    # Get function execution units
    local execution_units=$(az monitor metrics list \
        --resource "$function_id" \
        --metric "FunctionExecutionUnits" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --interval PT5M \
        --query "data[0].timeseries[0].data[0].total" -o tsv 2>/dev/null || echo "0")
    
    # Get function duration
    local avg_duration=$(az monitor metrics list \
        --resource "$function_id" \
        --metric "FunctionExecutionDuration" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --interval PT5M \
        --query "data[0].timeseries[0].data[0].average" -o tsv 2>/dev/null || echo "0")
    
    # Get function errors
    local error_count=$(az monitor metrics list \
        --resource "$function_id" \
        --metric "FunctionExecutionCount" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --interval PT5M \
        --query "data[0].timeseries[0].data[0].total" -o tsv 2>/dev/null || echo "0")
    
    # Get function throttles
    local throttle_count=$(az monitor metrics list \
        --resource "$function_id" \
        --metric "FunctionThrottles" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --interval PT5M \
        --query "data[0].timeseries[0].data[0].total" -o tsv 2>/dev/null || echo "0")
    
    # Get function memory usage
    local memory_usage=$(az monitor metrics list \
        --resource "$function_id" \
        --metric "FunctionMemoryUsage" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --interval PT5M \
        --query "data[0].timeseries[0].data[0].average" -o tsv 2>/dev/null || echo "0")
    
    # Check function status
    local function_status="unknown"
    local function_info=$(az functionapp function show \
        --name "$FUNCTION_APP_NAME" \
        --resource-group "$AZ_RESOURCE_GROUP" \
        --function-name "$function_name_clean" \
        --query "{isDisabled: isDisabled, triggerType: config.bindings[0].type, hasInvokeUrl: invokeUrlTemplate}" -o json 2>/dev/null || echo "{}")
    
    if [[ "$function_info" != "{}" ]]; then
        local is_disabled=$(echo "$function_info" | jq -r '.isDisabled // null')
        local trigger_type=$(echo "$function_info" | jq -r '.triggerType // "unknown"')
        local has_invoke_url=$(echo "$function_info" | jq -r '.hasInvokeUrl // ""')
        
        if [[ "$is_disabled" == "true" ]]; then
            function_status="disabled"
        elif [[ "$trigger_type" != "null" && "$trigger_type" != "unknown" && -n "$trigger_type" ]]; then
            function_status="$trigger_type"
        elif [[ -n "$has_invoke_url" ]]; then
            function_status="active"
        else
            function_status="unknown"
        fi
    fi
    
    # Create function summary
    local function_summary="Function: $function_name\n  - Executions: $execution_count\n  - Execution Units: $execution_units\n  - Avg Duration: ${avg_duration}ms\n  - Errors: $error_count\n  - Throttles: $throttle_count\n  - Memory Usage: ${memory_usage}MB\n  - Status: $function_status"
    
    # Append with a single newline
    SUMMARY_DATA+="$function_summary\n"
    
    # Check for issues and collect them for aggregation
    local issues_found=false
    local function_issues=()
    
    # Check if function has no executions (collect for aggregation)
    if [[ "$execution_count" == "0" || "$execution_count" == "null" ]]; then
        FUNCTIONS_WITH_NO_EXECUTIONS+=("$function_name")
        function_issues+=("No executions in the last $TIME_PERIOD_MINUTES minutes")
        issues_found=true
    fi
    
    # Check for high error rate (if there are executions)
    if [[ "$execution_count" -gt 0 && "$error_count" -gt 0 ]]; then
        local error_rate=$((error_count * 100 / execution_count))
        if [[ $error_rate -gt $FUNCTION_ERROR_RATE_THRESHOLD ]]; then
            FUNCTIONS_WITH_ERRORS+=("$function_name")
            function_issues+=("High error rate: ${error_rate}% ($error_count errors out of $execution_count executions)")
            issues_found=true
        fi
    fi
    
    # Check for throttles
    if [[ "$throttle_count" -gt 0 ]]; then
        FUNCTIONS_WITH_THROTTLES+=("$function_name")
        function_issues+=("Function is being throttled: $throttle_count throttles detected")
        issues_found=true
    fi
    
    # Check for high memory usage
    if [[ "$memory_usage" != "0" && "$memory_usage" != "null" ]]; then
        if (( $(echo "$memory_usage > $FUNCTION_MEMORY_THRESHOLD" | bc -l) )); then
            FUNCTIONS_WITH_HIGH_MEMORY+=("$function_name")
            function_issues+=("High memory usage: ${memory_usage}MB")
            issues_found=true
        fi
    fi
    
    # Check for slow execution
    if [[ "$avg_duration" != "0" && "$avg_duration" != "null" ]]; then
        if (( $(echo "$avg_duration > $FUNCTION_DURATION_THRESHOLD" | bc -l) )); then
            FUNCTIONS_WITH_SLOW_EXECUTION+=("$function_name")
            function_issues+=("Slow execution: ${avg_duration}ms average duration")
            issues_found=true
        fi
    fi
    
    echo "  ✅ Completed"
    echo ""
}

# Check each function
for function in $FUNCTIONS; do
    check_function_metrics "$function"
done

# Create aggregated issues based on collected data
echo ""
echo "📋 Creating Aggregated Issues"
echo "============================"

# Create aggregated issue for functions with no executions (severity 4)
if [[ ${#FUNCTIONS_WITH_NO_EXECUTIONS[@]} -gt 0 ]]; then
    no_exec_functions_list=""
    for func in "${FUNCTIONS_WITH_NO_EXECUTIONS[@]}"; do
        no_exec_functions_list+="- $func\n"
    done
    
    no_exec_details="Function App: $FUNCTION_APP_NAME\n"
    no_exec_details+="Resource Group: $AZ_RESOURCE_GROUP\n"
    no_exec_details+="Subscription: $AZURE_RESOURCE_SUBSCRIPTION_ID\n"
    no_exec_details+="Time Period: Last $TIME_PERIOD_MINUTES minutes\n"
    no_exec_details+="\nIssue: ${#FUNCTIONS_WITH_NO_EXECUTIONS[@]} function(s) have no executions\n"
    no_exec_details+="\nFunctions with no executions:\n"
    no_exec_details+="$no_exec_functions_list"
    no_exec_details+="\nPossible Causes:\n"
    no_exec_details+="- Functions are not triggered by any events\n"
    no_exec_details+="- Function triggers are not configured properly\n"
    no_exec_details+="- Functions are disabled or not deployed\n"
    no_exec_details+="- No events are being sent to trigger functions\n"
    no_exec_details+="\nNext Steps:\n"
    no_exec_details+="1. Review function trigger configurations\n"
    no_exec_details+="2. Check if functions are properly deployed\n"
    no_exec_details+="3. Verify that events are being sent to trigger functions\n"
    no_exec_details+="4. Monitor function logs for any deployment issues"
    
    # Escape special characters for JSON
    ESCAPED_FUNCTION_APP_NAME_NO_EXEC=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    ESCAPED_RESOURCE_GROUP_NO_EXEC=$(echo "$AZ_RESOURCE_GROUP" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    ESCAPED_NO_EXEC_DETAILS=$(echo "$no_exec_details" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    
    ISSUES+=("{\"title\":\"Function App '$ESCAPED_FUNCTION_APP_NAME_NO_EXEC' (RG: $ESCAPED_RESOURCE_GROUP_NO_EXEC) has ${#FUNCTIONS_WITH_NO_EXECUTIONS[@]} function(s) with no executions\",\"severity\":4,\"next_step\":\"Review function triggers and deployment status\",\"details\":\"$ESCAPED_NO_EXEC_DETAILS\"}")
    
    echo "  ✅ Created aggregated issue for ${#FUNCTIONS_WITH_NO_EXECUTIONS[@]} function(s) with no executions (Severity 4)"
fi

# Create aggregated issue for functions with high error rates (severity 2)
if [[ ${#FUNCTIONS_WITH_ERRORS[@]} -gt 0 ]]; then
    error_functions_list=""
    for func in "${FUNCTIONS_WITH_ERRORS[@]}"; do
        error_functions_list+="- $func\n"
    done
    
    error_details="Function App: $FUNCTION_APP_NAME\n"
    error_details+="Resource Group: $AZ_RESOURCE_GROUP\n"
    error_details+="Subscription: $AZURE_RESOURCE_SUBSCRIPTION_ID\n"
    error_details+="Time Period: Last $TIME_PERIOD_MINUTES minutes\n"
    error_details+="\nIssue: ${#FUNCTIONS_WITH_ERRORS[@]} function(s) have high error rates\n"
    error_details+="\nFunctions with high error rates:\n"
    error_details+="$error_functions_list"
    error_details+="\nNext Steps:\n"
    error_details+="1. Review individual function error logs\n"
    error_details+="2. Check function code for exceptions\n"
    error_details+="3. Verify input data and dependencies\n"
    error_details+="4. Monitor function performance and resource usage"
    
    # Escape special characters for JSON
    ESCAPED_FUNCTION_APP_NAME_ERROR=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    ESCAPED_RESOURCE_GROUP_ERROR=$(echo "$AZ_RESOURCE_GROUP" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    ESCAPED_ERROR_DETAILS=$(echo "$error_details" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    
    ISSUES+=("{\"title\":\"Function App '$ESCAPED_FUNCTION_APP_NAME_ERROR' (RG: $ESCAPED_RESOURCE_GROUP_ERROR) has ${#FUNCTIONS_WITH_ERRORS[@]} function(s) with high error rates\",\"severity\":2,\"next_step\":\"Investigate function errors and logs\",\"details\":\"$ESCAPED_ERROR_DETAILS\"}")
    
    echo "  ✅ Created aggregated issue for ${#FUNCTIONS_WITH_ERRORS[@]} function(s) with high error rates (Severity 2)"
fi

# Create aggregated issue for functions with throttles (severity 2)
if [[ ${#FUNCTIONS_WITH_THROTTLES[@]} -gt 0 ]]; then
    throttle_functions_list=""
    for func in "${FUNCTIONS_WITH_THROTTLES[@]}"; do
        throttle_functions_list+="- $func\n"
    done
    
    throttle_details="Function App: $FUNCTION_APP_NAME\n"
    throttle_details+="Resource Group: $AZ_RESOURCE_GROUP\n"
    throttle_details+="Subscription: $AZURE_RESOURCE_SUBSCRIPTION_ID\n"
    throttle_details+="Time Period: Last $TIME_PERIOD_MINUTES minutes\n"
    throttle_details+="\nIssue: ${#FUNCTIONS_WITH_THROTTLES[@]} function(s) are being throttled\n"
    throttle_details+="\nFunctions being throttled:\n"
    throttle_details+="$throttle_functions_list"
    throttle_details+="\nPossible Causes:\n"
    throttle_details+="- Consumption plan limits exceeded\n"
    throttle_details+="- High concurrent execution load\n"
    throttle_details+="- Resource constraints on function instances\n"
    throttle_details+="\nNext Steps:\n"
    throttle_details+="1. Check consumption plan limits and usage\n"
    throttle_details+="2. Consider upgrading to Premium plan\n"
    throttle_details+="3. Optimize function execution patterns\n"
    throttle_details+="4. Review function scaling configuration"
    
    # Escape special characters for JSON
    ESCAPED_FUNCTION_APP_NAME_THROTTLE=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    ESCAPED_RESOURCE_GROUP_THROTTLE=$(echo "$AZ_RESOURCE_GROUP" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    ESCAPED_THROTTLE_DETAILS=$(echo "$throttle_details" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    
    ISSUES+=("{\"title\":\"Function App '$ESCAPED_FUNCTION_APP_NAME_THROTTLE' (RG: $ESCAPED_RESOURCE_GROUP_THROTTLE) has ${#FUNCTIONS_WITH_THROTTLES[@]} function(s) being throttled\",\"severity\":2,\"next_step\":\"Check consumption plan limits or scale up\",\"details\":\"$ESCAPED_THROTTLE_DETAILS\"}")
    
    echo "  ✅ Created aggregated issue for ${#FUNCTIONS_WITH_THROTTLES[@]} function(s) being throttled (Severity 2)"
fi

# Create aggregated issue for functions with high memory usage (severity 3)
if [[ ${#FUNCTIONS_WITH_HIGH_MEMORY[@]} -gt 0 ]]; then
    memory_functions_list=""
    for func in "${FUNCTIONS_WITH_HIGH_MEMORY[@]}"; do
        memory_functions_list+="- $func\n"
    done
    
    memory_details="Function App: $FUNCTION_APP_NAME\n"
    memory_details+="Resource Group: $AZ_RESOURCE_GROUP\n"
    memory_details+="Subscription: $AZURE_RESOURCE_SUBSCRIPTION_ID\n"
    memory_details+="Time Period: Last $TIME_PERIOD_MINUTES minutes\n"
    memory_details+="\nIssue: ${#FUNCTIONS_WITH_HIGH_MEMORY[@]} function(s) have high memory usage\n"
    memory_details+="\nFunctions with high memory usage:\n"
    memory_details+="$memory_functions_list"
    memory_details+="\nNext Steps:\n"
    memory_details+="1. Review function code for memory leaks\n"
    memory_details+="2. Optimize memory usage in functions\n"
    memory_details+="3. Consider increasing memory allocation\n"
    memory_details+="4. Monitor memory usage trends"
    
    # Escape special characters for JSON
    ESCAPED_FUNCTION_APP_NAME_MEMORY=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    ESCAPED_RESOURCE_GROUP_MEMORY=$(echo "$AZ_RESOURCE_GROUP" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    ESCAPED_MEMORY_DETAILS=$(echo "$memory_details" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    
    ISSUES+=("{\"title\":\"Function App '$ESCAPED_FUNCTION_APP_NAME_MEMORY' (RG: $ESCAPED_RESOURCE_GROUP_MEMORY) has ${#FUNCTIONS_WITH_HIGH_MEMORY[@]} function(s) with high memory usage\",\"severity\":3,\"next_step\":\"Review function memory usage and optimization\",\"details\":\"$ESCAPED_MEMORY_DETAILS\"}")
    
    echo "  ✅ Created aggregated issue for ${#FUNCTIONS_WITH_HIGH_MEMORY[@]} function(s) with high memory usage (Severity 3)"
fi

# Create aggregated issue for functions with slow execution (severity 3)
if [[ ${#FUNCTIONS_WITH_SLOW_EXECUTION[@]} -gt 0 ]]; then
    slow_functions_list=""
    for func in "${FUNCTIONS_WITH_SLOW_EXECUTION[@]}"; do
        slow_functions_list+="- $func\n"
    done
    
    slow_details="Function App: $FUNCTION_APP_NAME\n"
    slow_details+="Resource Group: $AZ_RESOURCE_GROUP\n"
    slow_details+="Subscription: $AZURE_RESOURCE_SUBSCRIPTION_ID\n"
    slow_details+="Time Period: Last $TIME_PERIOD_MINUTES minutes\n"
    slow_details+="\nIssue: ${#FUNCTIONS_WITH_SLOW_EXECUTION[@]} function(s) have slow execution times\n"
    slow_details+="\nFunctions with slow execution:\n"
    slow_details+="$slow_functions_list"
    slow_details+="\nNext Steps:\n"
    slow_details+="1. Review function code for performance bottlenecks\n"
    slow_details+="2. Optimize database queries and external calls\n"
    slow_details+="3. Consider async/await patterns\n"
    slow_details+="4. Monitor execution time trends"
    
    # Escape special characters for JSON
    ESCAPED_FUNCTION_APP_NAME_SLOW=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    ESCAPED_RESOURCE_GROUP_SLOW=$(echo "$AZ_RESOURCE_GROUP" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    ESCAPED_SLOW_DETAILS=$(echo "$slow_details" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    
    ISSUES+=("{\"title\":\"Function App '$ESCAPED_FUNCTION_APP_NAME_SLOW' (RG: $ESCAPED_RESOURCE_GROUP_SLOW) has ${#FUNCTIONS_WITH_SLOW_EXECUTION[@]} function(s) with slow execution times\",\"severity\":3,\"next_step\":\"Review function performance and optimization\",\"details\":\"$ESCAPED_SLOW_DETAILS\"}")
    
    echo "  ✅ Created aggregated issue for ${#FUNCTIONS_WITH_SLOW_EXECUTION[@]} function(s) with slow execution times (Severity 3)"
fi

# Get overall function app metrics
echo ""
echo "📊 Checking Overall Function App Metrics"
echo "======================================="

# Get total executions
TOTAL_EXECUTIONS=$(az monitor metrics list \
    --resource "$FUNCTION_APP_ID" \
    --metric "FunctionExecutionCount" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --interval PT5M \
    --query "data[0].timeseries[0].data[0].total" -o tsv 2>/dev/null || echo "0")

# Get total errors
TOTAL_ERRORS=$(az monitor metrics list \
    --resource "$FUNCTION_APP_ID" \
    --metric "FunctionExecutionCount" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --interval PT5M \
    --query "data[0].timeseries[0].data[0].total" -o tsv 2>/dev/null || echo "0")

# Get total throttles
TOTAL_THROTTLES=$(az monitor metrics list \
    --resource "$FUNCTION_APP_ID" \
    --metric "FunctionThrottles" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --interval PT5M \
    --query "data[0].timeseries[0].data[0].total" -o tsv 2>/dev/null || echo "0")

# Calculate overall error rate
OVERALL_ERROR_RATE=0
if [[ "$TOTAL_EXECUTIONS" -gt 0 ]]; then
    OVERALL_ERROR_RATE=$((TOTAL_ERRORS * 100 / TOTAL_EXECUTIONS))
fi

# Add overall issues if needed
if [[ "$TOTAL_EXECUTIONS" == "0" ]]; then
    no_exec_details="Function App: $FUNCTION_APP_NAME\n"
    no_exec_details+="Resource Group: $AZ_RESOURCE_GROUP\n"
    no_exec_details+="Subscription: $AZURE_RESOURCE_SUBSCRIPTION_ID\n"
    no_exec_details+="Time Period: Last $TIME_PERIOD_MINUTES minutes\n"
    no_exec_details+="Total Functions: $(echo "$FUNCTIONS" | wc -w)\n"
    no_exec_details+="\nIssue: No function executions detected in the specified time period\n"
    no_exec_details+="\nPossible Causes:\n"
    no_exec_details+="- Function triggers are not configured properly\n"
    no_exec_details+="- Functions are disabled or not deployed\n"
    no_exec_details+="- No events are being sent to trigger functions\n"
    no_exec_details+="- Function App is in stopped state\n"
    no_exec_details+="\nNext Steps:\n"
    no_exec_details+="1. Check function trigger configurations\n"
    no_exec_details+="2. Verify function deployment status\n"
    no_exec_details+="3. Review function app state and settings\n"
    no_exec_details+="4. Check for any deployment or configuration issues"
    
    # Escape special characters for JSON
    ESCAPED_FUNCTION_APP_NAME_NO_EXEC=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    ESCAPED_RESOURCE_GROUP_NO_EXEC=$(echo "$AZ_RESOURCE_GROUP" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    ESCAPED_NO_EXEC_DETAILS=$(echo "$no_exec_details" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    
    ISSUES+=("{\"title\":\"Function App '$ESCAPED_FUNCTION_APP_NAME_NO_EXEC' (RG: $ESCAPED_RESOURCE_GROUP_NO_EXEC) has no executions in last $TIME_PERIOD_MINUTES minutes\",\"severity\":3,\"next_step\":\"Check function triggers and configuration\",\"details\":\"$ESCAPED_NO_EXEC_DETAILS\"}")
fi

if [[ $OVERALL_ERROR_RATE -gt 20 ]]; then
    error_details="Function App: $FUNCTION_APP_NAME\n"
    error_details+="Resource Group: $AZ_RESOURCE_GROUP\n"
    error_details+="Subscription: $AZURE_RESOURCE_SUBSCRIPTION_ID\n"
    error_details+="Time Period: Last $TIME_PERIOD_MINUTES minutes\n"
    error_details+="\nMetrics:\n"
    error_details+="- Total Executions: $TOTAL_EXECUTIONS\n"
    error_details+="- Total Errors: $TOTAL_ERRORS\n"
    error_details+="- Error Rate: ${OVERALL_ERROR_RATE}%\n"
    error_details+="- Total Functions: $(echo "$FUNCTIONS" | wc -w)\n"
    error_details+="\nIssue: High overall error rate detected\n"
    error_details+="\nNext Steps:\n"
    error_details+="1. Review individual function error logs\n"
    error_details+="2. Check function code for exceptions\n"
    error_details+="3. Verify input data and dependencies\n"
    error_details+="4. Monitor function performance and resource usage"
    
    # Escape special characters for JSON
    ESCAPED_FUNCTION_APP_NAME_ERROR=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    ESCAPED_RESOURCE_GROUP_ERROR=$(echo "$AZ_RESOURCE_GROUP" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    ESCAPED_ERROR_DETAILS=$(echo "$error_details" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    
    ISSUES+=("{\"title\":\"Function App '$ESCAPED_FUNCTION_APP_NAME_ERROR' (RG: $ESCAPED_RESOURCE_GROUP_ERROR) has high error rate of ${OVERALL_ERROR_RATE}%\",\"severity\":1,\"next_step\":\"Investigate function errors and logs\",\"details\":\"$ESCAPED_ERROR_DETAILS\"}")
fi

if [[ "$TOTAL_THROTTLES" -gt 0 ]]; then
    throttle_details="Function App: $FUNCTION_APP_NAME\n"
    throttle_details+="Resource Group: $AZ_RESOURCE_GROUP\n"
    throttle_details+="Subscription: $AZURE_RESOURCE_SUBSCRIPTION_ID\n"
    throttle_details+="Time Period: Last $TIME_PERIOD_MINUTES minutes\n"
    throttle_details+="\nMetrics:\n"
    throttle_details+="- Total Throttles: $TOTAL_THROTTLES\n"
    throttle_details+="- Total Executions: $TOTAL_EXECUTIONS\n"
    throttle_details+="- Total Functions: $(echo "$FUNCTIONS" | wc -w)\n"
    throttle_details+="\nIssue: Function App is being throttled\n"
    throttle_details+="\nPossible Causes:\n"
    throttle_details+="- Consumption plan limits exceeded\n"
    throttle_details+="- High concurrent execution load\n"
    throttle_details+="- Resource constraints on function instances\n"
    throttle_details+="\nNext Steps:\n"
    throttle_details+="1. Check consumption plan limits and usage\n"
    throttle_details+="2. Consider upgrading to Premium plan\n"
    throttle_details+="3. Optimize function execution patterns\n"
    throttle_details+="4. Review function scaling configuration"
    
    # Escape special characters for JSON
    ESCAPED_FUNCTION_APP_NAME_THROTTLE=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    ESCAPED_RESOURCE_GROUP_THROTTLE=$(echo "$AZ_RESOURCE_GROUP" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    ESCAPED_THROTTLE_DETAILS=$(echo "$throttle_details" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    
    ISSUES+=("{\"title\":\"Function App '$ESCAPED_FUNCTION_APP_NAME_THROTTLE' (RG: $ESCAPED_RESOURCE_GROUP_THROTTLE) is being throttled ($TOTAL_THROTTLES throttles)\",\"severity\":2,\"next_step\":\"Check consumption plan limits or scale up\",\"details\":\"$ESCAPED_THROTTLE_DETAILS\"}")
fi

# Create summary
OVERALL_SUMMARY="Function App Invocation Health Report
================================================

Function App Details:
- Name: $FUNCTION_APP_NAME
- Resource Group: $AZ_RESOURCE_GROUP
- Subscription: $AZURE_RESOURCE_SUBSCRIPTION_ID
- Time Period: Last $TIME_PERIOD_MINUTES minutes

Overall Metrics:
- Total Functions: $(echo "$FUNCTIONS" | wc -w)
- Total Executions: $TOTAL_EXECUTIONS
- Total Errors: $TOTAL_ERRORS
- Total Throttles: $TOTAL_THROTTLES
- Overall Error Rate: ${OVERALL_ERROR_RATE}%
- Issues Found: ${#ISSUES[@]}

Thresholds Used:
- Error Rate Threshold: ${FUNCTION_ERROR_RATE_THRESHOLD}%
- Memory Usage Threshold: ${FUNCTION_MEMORY_THRESHOLD}MB
- Duration Threshold: ${FUNCTION_DURATION_THRESHOLD}ms

Function Details:
$SUMMARY_DATA

Report Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"

echo "$OVERALL_SUMMARY" > function_invocation_summary.txt

# Create JSON output with proper validation
# Ensure all values are valid numbers or strings
TOTAL_FUNCTIONS=$(echo "$FUNCTIONS" | wc -w)
TOTAL_EXECUTIONS_VALID=${TOTAL_EXECUTIONS:-0}
TOTAL_ERRORS_VALID=${TOTAL_ERRORS:-0}
TOTAL_THROTTLES_VALID=${TOTAL_THROTTLES:-0}
OVERALL_ERROR_RATE_VALID=${OVERALL_ERROR_RATE:-0}

# Validate that values are numeric
if [[ ! "$TOTAL_EXECUTIONS_VALID" =~ ^[0-9]+$ ]]; then
    TOTAL_EXECUTIONS_VALID=0
fi
if [[ ! "$TOTAL_ERRORS_VALID" =~ ^[0-9]+$ ]]; then
    TOTAL_ERRORS_VALID=0
fi
if [[ ! "$TOTAL_THROTTLES_VALID" =~ ^[0-9]+$ ]]; then
    TOTAL_THROTTLES_VALID=0
fi
if [[ ! "$OVERALL_ERROR_RATE_VALID" =~ ^[0-9]+$ ]]; then
    OVERALL_ERROR_RATE_VALID=0
fi

JSON_OUTPUT="{\"issues\":["
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    JSON_OUTPUT+=$(IFS=,; echo "${ISSUES[*]}")
fi
JSON_OUTPUT+="],\"summary\":{\"total_functions\":$TOTAL_FUNCTIONS,\"total_executions\":$TOTAL_EXECUTIONS_VALID,\"total_errors\":$TOTAL_ERRORS_VALID,\"total_throttles\":$TOTAL_THROTTLES_VALID,\"error_rate\":$OVERALL_ERROR_RATE_VALID}}"

# Validate JSON before writing to file
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
echo "Subscription: $AZURE_RESOURCE_SUBSCRIPTION_ID"
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