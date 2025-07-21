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
    echo "{\"issues\":[],\"summary\":{\"total_functions\":0,\"total_executions\":0,\"total_errors\":0,\"total_throttles\":0,\"error_rate\":0,\"avg_duration\":0,\"avg_memory\":0}}" > function_invocation_health.json
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

# Helper function to safely get numeric value
get_numeric_value() {
    local value="$1"
    local default="$2"
    if [[ -z "$value" || "$value" == "null" || "$value" == "" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
}

# Helper function to format value for display
format_display_value() {
    local value="$1"
    local unit="$2"
    local default="$3"
    
    if [[ -z "$value" || "$value" == "null" || "$value" == "0" ]]; then
        echo "$default"
    else
        echo "${value}${unit}"
    fi
}

echo "🔍 Checking Function App Level Metrics"
echo "====================================="

# Get Function App level metrics for overall health picture
echo "📊 Querying Function App level metrics..."

# Get overall execution count
TOTAL_EXECUTIONS_RAW=$(az monitor metrics list \
    --resource "$FUNCTION_APP_ID" \
    --metric "FunctionExecutionCount" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --interval PT5M \
    --query "data[0].timeseries[0].data[0].total" -o tsv 2>/dev/null || echo "0")

# Get overall execution units
TOTAL_EXECUTION_UNITS_RAW=$(az monitor metrics list \
    --resource "$FUNCTION_APP_ID" \
    --metric "FunctionExecutionUnits" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --interval PT5M \
    --query "data[0].timeseries[0].data[0].total" -o tsv 2>/dev/null || echo "0")

# Get overall errors
TOTAL_ERRORS_RAW=$(az monitor metrics list \
    --resource "$FUNCTION_APP_ID" \
    --metric "FunctionErrors" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --interval PT5M \
    --query "data[0].timeseries[0].data[0].total" -o tsv 2>/dev/null || echo "0")

# Get overall throttles
TOTAL_THROTTLES_RAW=$(az monitor metrics list \
    --resource "$FUNCTION_APP_ID" \
    --metric "FunctionThrottles" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --interval PT5M \
    --query "data[0].timeseries[0].data[0].total" -o tsv 2>/dev/null || echo "0")

# Get average duration
AVG_DURATION_RAW=$(az monitor metrics list \
    --resource "$FUNCTION_APP_ID" \
    --metric "FunctionExecutionDuration" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --interval PT5M \
    --query "data[0].timeseries[0].data[0].average" -o tsv 2>/dev/null || echo "0")

# Get average memory usage
AVG_MEMORY_RAW=$(az monitor metrics list \
    --resource "$FUNCTION_APP_ID" \
    --metric "FunctionMemoryUsage" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --interval PT5M \
    --query "data[0].timeseries[0].data[0].average" -o tsv 2>/dev/null || echo "0")

# Normalize values
TOTAL_EXECUTIONS=$(get_numeric_value "$TOTAL_EXECUTIONS_RAW" "0")
TOTAL_EXECUTION_UNITS=$(get_numeric_value "$TOTAL_EXECUTION_UNITS_RAW" "0")
TOTAL_ERRORS=$(get_numeric_value "$TOTAL_ERRORS_RAW" "0")
TOTAL_THROTTLES=$(get_numeric_value "$TOTAL_THROTTLES_RAW" "0")
AVG_DURATION=$(get_numeric_value "$AVG_DURATION_RAW" "0")
AVG_MEMORY=$(get_numeric_value "$AVG_MEMORY_RAW" "0")

echo "✅ Function App level metrics retrieved"
echo ""

echo "🔍 Checking Per-Function Metrics (Efficient Approach)"
echo "===================================================="

# Get per-function metrics using dimension filtering (much more efficient)
echo "📊 Querying per-function metrics with dimension filtering..."

# Get per-function execution counts
echo "  - Getting execution counts per function..."
FUNCTION_EXECUTIONS_JSON=$(az monitor metrics list \
    --resource "$FUNCTION_APP_ID" \
    --metric "FunctionExecutionCount" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --interval PT5M \
    --query "data[0].timeseries[?dimensions.FunctionName].{function: dimensions.FunctionName, total: data[0].total}" \
    -o json 2>/dev/null || echo "[]")

# Get per-function errors
echo "  - Getting errors per function..."
FUNCTION_ERRORS_JSON=$(az monitor metrics list \
    --resource "$FUNCTION_APP_ID" \
    --metric "FunctionErrors" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --interval PT5M \
    --query "data[0].timeseries[?dimensions.FunctionName].{function: dimensions.FunctionName, total: data[0].total}" \
    -o json 2>/dev/null || echo "[]")

# Get per-function throttles
echo "  - Getting throttles per function..."
FUNCTION_THROTTLES_JSON=$(az monitor metrics list \
    --resource "$FUNCTION_APP_ID" \
    --metric "FunctionThrottles" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --interval PT5M \
    --query "data[0].timeseries[?dimensions.FunctionName].{function: dimensions.FunctionName, total: data[0].total}" \
    -o json 2>/dev/null || echo "[]")

# Get per-function durations
echo "  - Getting durations per function..."
FUNCTION_DURATIONS_JSON=$(az monitor metrics list \
    --resource "$FUNCTION_APP_ID" \
    --metric "FunctionExecutionDuration" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --interval PT5M \
    --query "data[0].timeseries[?dimensions.FunctionName].{function: dimensions.FunctionName, average: data[0].average}" \
    -o json 2>/dev/null || echo "[]")

# Get per-function memory usage
echo "  - Getting memory usage per function..."
FUNCTION_MEMORY_JSON=$(az monitor metrics list \
    --resource "$FUNCTION_APP_ID" \
    --metric "FunctionMemoryUsage" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --interval PT5M \
    --query "data[0].timeseries[?dimensions.FunctionName].{function: dimensions.FunctionName, average: data[0].average}" \
    -o json 2>/dev/null || echo "[]")

echo "✅ Per-function metrics retrieved"
echo ""

# Process per-function data and create detailed summary
echo "📋 Processing Per-Function Data"
echo "==============================="

# Initialize per-function data arrays
declare -A FUNCTION_EXECUTIONS
declare -A FUNCTION_ERRORS
declare -A FUNCTION_THROTTLES
declare -A FUNCTION_DURATIONS
declare -A FUNCTION_MEMORY

# Parse execution counts
if [[ "$FUNCTION_EXECUTIONS_JSON" != "[]" ]]; then
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            func_name=$(echo "$line" | jq -r '.function' 2>/dev/null)
            exec_count=$(echo "$line" | jq -r '.total' 2>/dev/null)
            if [[ -n "$func_name" && "$func_name" != "null" ]]; then
                FUNCTION_EXECUTIONS["$func_name"]=$(get_numeric_value "$exec_count" "0")
            fi
        fi
    done < <(echo "$FUNCTION_EXECUTIONS_JSON" | jq -c '.[]' 2>/dev/null || echo "")
fi

# Parse errors
if [[ "$FUNCTION_ERRORS_JSON" != "[]" ]]; then
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            func_name=$(echo "$line" | jq -r '.function' 2>/dev/null)
            error_count=$(echo "$line" | jq -r '.total' 2>/dev/null)
            if [[ -n "$func_name" && "$func_name" != "null" ]]; then
                FUNCTION_ERRORS["$func_name"]=$(get_numeric_value "$error_count" "0")
            fi
        fi
    done < <(echo "$FUNCTION_ERRORS_JSON" | jq -c '.[]' 2>/dev/null || echo "")
fi

# Parse throttles
if [[ "$FUNCTION_THROTTLES_JSON" != "[]" ]]; then
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            func_name=$(echo "$line" | jq -r '.function' 2>/dev/null)
            throttle_count=$(echo "$line" | jq -r '.total' 2>/dev/null)
            if [[ -n "$func_name" && "$func_name" != "null" ]]; then
                FUNCTION_THROTTLES["$func_name"]=$(get_numeric_value "$throttle_count" "0")
            fi
        fi
    done < <(echo "$FUNCTION_THROTTLES_JSON" | jq -c '.[]' 2>/dev/null || echo "")
fi

# Parse durations
if [[ "$FUNCTION_DURATIONS_JSON" != "[]" ]]; then
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            func_name=$(echo "$line" | jq -r '.function' 2>/dev/null)
            duration=$(echo "$line" | jq -r '.average' 2>/dev/null)
            if [[ -n "$func_name" && "$func_name" != "null" ]]; then
                FUNCTION_DURATIONS["$func_name"]=$(get_numeric_value "$duration" "0")
            fi
        fi
    done < <(echo "$FUNCTION_DURATIONS_JSON" | jq -c '.[]' 2>/dev/null || echo "")
fi

# Parse memory usage
if [[ "$FUNCTION_MEMORY_JSON" != "[]" ]]; then
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            func_name=$(echo "$line" | jq -r '.function' 2>/dev/null)
            memory=$(echo "$line" | jq -r '.average' 2>/dev/null)
            if [[ -n "$func_name" && "$func_name" != "null" ]]; then
                FUNCTION_MEMORY["$func_name"]=$(get_numeric_value "$memory" "0")
            fi
        fi
    done < <(echo "$FUNCTION_MEMORY_JSON" | jq -c '.[]' 2>/dev/null || echo "")
fi

# Calculate overall error rate
OVERALL_ERROR_RATE="0"
if [[ "$TOTAL_EXECUTIONS" != "0" ]]; then
    OVERALL_ERROR_RATE=$(echo "scale=2; $TOTAL_ERRORS * 100 / $TOTAL_EXECUTIONS" | bc -l 2>/dev/null || echo "0")
fi

# Create summary data with per-function details
SUMMARY_DATA="Function App: $FUNCTION_APP_NAME
Resource Group: $AZ_RESOURCE_GROUP
Subscription: $SUBSCRIPTION_NAME
Time Period: Last $TIME_PERIOD_MINUTES minutes

Overall Metrics:
- Total Executions: $(format_display_value "$TOTAL_EXECUTIONS" "" "0")
- Total Execution Units: $(format_display_value "$TOTAL_EXECUTION_UNITS" "" "0")
- Total Errors: $(format_display_value "$TOTAL_ERRORS" "" "0")
- Total Throttles: $(format_display_value "$TOTAL_THROTTLES" "" "0")
- Average Duration: $(format_display_value "$AVG_DURATION" "ms" "0ms")
- Average Memory Usage: $(format_display_value "$AVG_MEMORY" "MB" "0MB")
- Overall Error Rate: $(format_display_value "$OVERALL_ERROR_RATE" "%" "0%")

Per-Function Metrics:
===================="

# Process each function and add to summary
for func in $FUNCTIONS; do
    executions=${FUNCTION_EXECUTIONS["$func"]:-0}
    errors=${FUNCTION_ERRORS["$func"]:-0}
    throttles=${FUNCTION_THROTTLES["$func"]:-0}
    duration=${FUNCTION_DURATIONS["$func"]:-0}
    memory=${FUNCTION_MEMORY["$func"]:-0}
    
    # Calculate error rate for this function
    error_rate="0"
    if [[ "$executions" != "0" ]]; then
        error_rate=$(echo "scale=2; $errors * 100 / $executions" | bc -l 2>/dev/null || echo "0")
    fi
    
    SUMMARY_DATA="$SUMMARY_DATA

Function: $func
- Executions: $executions
- Errors: $errors
- Throttles: $throttles
- Error Rate: ${error_rate}%
- Average Duration: ${duration}ms
- Average Memory: ${memory}MB"
    
    # Check for issues per function
    if [[ "$executions" == "0" ]]; then
        FUNCTIONS_WITH_NO_EXECUTIONS+=("$func")
    fi
    
    if [[ "$errors" != "0" ]]; then
        if (( $(echo "$error_rate > $FUNCTION_ERROR_RATE_THRESHOLD" | bc -l) )); then
            FUNCTIONS_WITH_ERRORS+=("$func")
        fi
    fi
    
    if [[ "$throttles" != "0" ]]; then
        FUNCTIONS_WITH_THROTTLES+=("$func")
    fi
    
    if [[ "$memory" != "0" ]]; then
        if (( $(echo "$memory > $FUNCTION_MEMORY_THRESHOLD" | bc -l) )); then
            FUNCTIONS_WITH_HIGH_MEMORY+=("$func")
        fi
    fi
    
    if [[ "$duration" != "0" ]]; then
        if (( $(echo "$duration > $FUNCTION_DURATION_THRESHOLD" | bc -l) )); then
            FUNCTIONS_WITH_SLOW_EXECUTION+=("$func")
        fi
    fi
done

echo "✅ Per-function data processed"
echo ""

echo "📋 Creating Issues Based on Per-Function Metrics"
echo "==============================================="

# Create issues for functions with no executions (only if time period is reasonable)
if [[ ${#FUNCTIONS_WITH_NO_EXECUTIONS[@]} -gt 0 ]]; then
    # Only create issue if time period is >= 30 minutes (short periods might be normal)
    if [[ $TIME_PERIOD_MINUTES -ge 30 ]]; then
        echo "⚠️  Functions with no executions: ${FUNCTIONS_WITH_NO_EXECUTIONS[*]}"
        
        no_exec_details="Function App: $FUNCTION_APP_NAME
Resource Group: $AZ_RESOURCE_GROUP
Subscription: $SUBSCRIPTION_NAME
Time Period: Last $TIME_PERIOD_MINUTES minutes

Issue: Functions with no executions
Affected Functions: ${FUNCTIONS_WITH_NO_EXECUTIONS[*]}

This may indicate:
- Functions are not being triggered by events
- Function triggers are misconfigured
- Functions are disabled or not deployed
- No events are being sent to trigger functions

Next Steps:
Review function trigger configurations and verify that events are being sent to trigger functions. Check function app logs for deployment issues."
        
        # Escape for JSON
        ESCAPED_NO_EXEC_DETAILS=$(echo "$no_exec_details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
        ESCAPED_FUNCTION_APP_NAME_NO_EXEC=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g')
        ESCAPED_SUBSCRIPTION_NAME_NO_EXEC=$(echo "$SUBSCRIPTION_NAME" | sed 's/"/\\"/g')
        
        ISSUES+=("{\"title\":\"Function App \`$ESCAPED_FUNCTION_APP_NAME_NO_EXEC\` in subscription \`$ESCAPED_SUBSCRIPTION_NAME_NO_EXEC\` has idle functions with no executions\",\"severity\":3,\"next_step\":\"Review function trigger configurations and verify event sources are active\",\"details\":\"$ESCAPED_NO_EXEC_DETAILS\"}")
        
        echo "  ✅ Created issue for functions with no executions (Severity 3)"
    else
        echo "ℹ️  Functions with no executions: ${FUNCTIONS_WITH_NO_EXECUTIONS[*]} (Normal for short time periods)"
    fi
fi

# Create issues for functions with high error rates
if [[ ${#FUNCTIONS_WITH_ERRORS[@]} -gt 0 ]]; then
    echo "⚠️  Functions with high error rates: ${FUNCTIONS_WITH_ERRORS[*]}"
    
    error_details="Function App: $FUNCTION_APP_NAME
Resource Group: $AZ_RESOURCE_GROUP
Subscription: $SUBSCRIPTION_NAME
Time Period: Last $TIME_PERIOD_MINUTES minutes

Issue: Functions with high error rates
Affected Functions: ${FUNCTIONS_WITH_ERRORS[*]}
Threshold: ${FUNCTION_ERROR_RATE_THRESHOLD}%

Per-Function Details:"
    
    for func in "${FUNCTIONS_WITH_ERRORS[@]}"; do
        executions=${FUNCTION_EXECUTIONS["$func"]:-0}
        errors=${FUNCTION_ERRORS["$func"]:-0}
        error_rate="0"
        if [[ "$executions" != "0" ]]; then
            error_rate=$(echo "scale=2; $errors * 100 / $executions" | bc -l 2>/dev/null || echo "0")
        fi
        error_details="$error_details
- $func: $errors errors out of $executions executions (${error_rate}%)"
    done
    
    error_details="$error_details

Possible Causes:
- Code bugs or exceptions in functions
- Configuration issues
- Resource constraints (memory, CPU)
- External service dependencies failing

Next Steps:
Review function logs for error details and check function code for bugs. Verify external dependencies and monitor resource usage."
    
    # Escape for JSON
    ESCAPED_ERROR_DETAILS=$(echo "$error_details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    ESCAPED_FUNCTION_APP_NAME_ERROR=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g')
    ESCAPED_SUBSCRIPTION_NAME_ERROR=$(echo "$SUBSCRIPTION_NAME" | sed 's/"/\\"/g')
    
    ISSUES+=("{\"title\":\"Function App \`$ESCAPED_FUNCTION_APP_NAME_ERROR\` in subscription \`$ESCAPED_SUBSCRIPTION_NAME_ERROR\` has functions failing with high error rates\",\"severity\":1,\"next_step\":\"Review function logs and investigate code bugs or dependency failures\",\"details\":\"$ESCAPED_ERROR_DETAILS\"}")
    
    echo "  ✅ Created issue for functions with high error rates (Severity 1)"
fi

# Create issues for functions with throttles
if [[ ${#FUNCTIONS_WITH_THROTTLES[@]} -gt 0 ]]; then
    echo "⚠️  Functions with throttles: ${FUNCTIONS_WITH_THROTTLES[*]}"
    
    throttle_details="Function App: $FUNCTION_APP_NAME
Resource Group: $AZ_RESOURCE_GROUP
Subscription: $SUBSCRIPTION_NAME
Time Period: Last $TIME_PERIOD_MINUTES minutes

Issue: Functions being throttled
Affected Functions: ${FUNCTIONS_WITH_THROTTLES[*]}

Per-Function Details:"
    
    for func in "${FUNCTIONS_WITH_THROTTLES[@]}"; do
        throttles=${FUNCTION_THROTTLES["$func"]:-0}
        throttle_details="$throttle_details
- $func: $throttles throttles"
    done
    
    throttle_details="$throttle_details

Possible Causes:
- Consumption plan limits exceeded
- High concurrent execution count
- Resource constraints

Next Steps:
Consider upgrading to a higher tier plan or implement retry logic with exponential backoff. Optimize function execution patterns."
    
    # Escape for JSON
    ESCAPED_THROTTLE_DETAILS=$(echo "$throttle_details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    ESCAPED_FUNCTION_APP_NAME_THROTTLE=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g')
    ESCAPED_SUBSCRIPTION_NAME_THROTTLE=$(echo "$SUBSCRIPTION_NAME" | sed 's/"/\\"/g')
    
    ISSUES+=("{\"title\":\"Function App \`$ESCAPED_FUNCTION_APP_NAME_THROTTLE\` in subscription \`$ESCAPED_SUBSCRIPTION_NAME_THROTTLE\` is throttling functions due to plan limits\",\"severity\":2,\"next_step\":\"Upgrade to premium plan or implement retry logic to handle throttling\",\"details\":\"$ESCAPED_THROTTLE_DETAILS\"}")
    
    echo "  ✅ Created issue for functions with throttles (Severity 2)"
fi

# Create issues for functions with high memory usage
if [[ ${#FUNCTIONS_WITH_HIGH_MEMORY[@]} -gt 0 ]]; then
    echo "⚠️  Functions with high memory usage: ${FUNCTIONS_WITH_HIGH_MEMORY[*]}"
    
    memory_details="Function App: $FUNCTION_APP_NAME
Resource Group: $AZ_RESOURCE_GROUP
Subscription: $SUBSCRIPTION_NAME
Time Period: Last $TIME_PERIOD_MINUTES minutes

Issue: Functions with high memory usage
Affected Functions: ${FUNCTIONS_WITH_HIGH_MEMORY[*]}
Threshold: ${FUNCTION_MEMORY_THRESHOLD}MB

Per-Function Details:"
    
    for func in "${FUNCTIONS_WITH_HIGH_MEMORY[@]}"; do
        memory=${FUNCTION_MEMORY["$func"]:-0}
        memory_details="$memory_details
- $func: ${memory}MB average"
    done
    
    memory_details="$memory_details

Possible Causes:
- Memory leaks in function code
- Large data processing
- Inefficient memory usage patterns

Next Steps:
Review function code for memory leaks and optimize data processing patterns. Consider increasing memory allocation."
    
    # Escape for JSON
    ESCAPED_MEMORY_DETAILS=$(echo "$memory_details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    ESCAPED_FUNCTION_APP_NAME_MEMORY=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g')
    ESCAPED_SUBSCRIPTION_NAME_MEMORY=$(echo "$SUBSCRIPTION_NAME" | sed 's/"/\\"/g')
    
    ISSUES+=("{\"title\":\"Function App \`$ESCAPED_FUNCTION_APP_NAME_MEMORY\` in subscription \`$ESCAPED_SUBSCRIPTION_NAME_MEMORY\` has functions consuming excessive memory\",\"severity\":3,\"next_step\":\"Optimize function memory usage and check for memory leaks in code\",\"details\":\"$ESCAPED_MEMORY_DETAILS\"}")
    
    echo "  ✅ Created issue for functions with high memory usage (Severity 3)"
fi

# Create issues for functions with slow execution
if [[ ${#FUNCTIONS_WITH_SLOW_EXECUTION[@]} -gt 0 ]]; then
    echo "⚠️  Functions with slow execution: ${FUNCTIONS_WITH_SLOW_EXECUTION[*]}"
    
    slow_details="Function App: $FUNCTION_APP_NAME
Resource Group: $AZ_RESOURCE_GROUP
Subscription: $SUBSCRIPTION_NAME
Time Period: Last $TIME_PERIOD_MINUTES minutes

Issue: Functions with slow execution
Affected Functions: ${FUNCTIONS_WITH_SLOW_EXECUTION[*]}
Threshold: ${FUNCTION_DURATION_THRESHOLD}ms

Per-Function Details:"
    
    for func in "${FUNCTIONS_WITH_SLOW_EXECUTION[@]}"; do
        duration=${FUNCTION_DURATIONS["$func"]:-0}
        slow_details="$slow_details
- $func: ${duration}ms average"
    done
    
    slow_details="$slow_details

Possible Causes:
- Inefficient algorithms
- External service dependencies
- Resource constraints
- Cold starts

Next Steps:
Profile function performance and optimize algorithms. Review external dependencies and consider using premium plan for better performance."
    
    # Escape for JSON
    ESCAPED_SLOW_DETAILS=$(echo "$slow_details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    ESCAPED_FUNCTION_APP_NAME_SLOW=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g')
    ESCAPED_SUBSCRIPTION_NAME_SLOW=$(echo "$SUBSCRIPTION_NAME" | sed 's/"/\\"/g')
    
    ISSUES+=("{\"title\":\"Function App \`$ESCAPED_FUNCTION_APP_NAME_SLOW\` in subscription \`$ESCAPED_SUBSCRIPTION_NAME_SLOW\` has functions with slow execution times\",\"severity\":3,\"next_step\":\"Profile function performance and optimize slow algorithms or external dependencies\",\"details\":\"$ESCAPED_SLOW_DETAILS\"}")
    
    echo "  ✅ Created issue for functions with slow execution (Severity 3)"
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
        echo "$JSON_OUTPUT" | jq '.' > function_invocation_health.json
        echo "✅ JSON validation passed"
    else
        echo "❌ JSON validation failed - generating fallback JSON"
        echo '{"issues":[],"summary":{"total_functions":0,"total_executions":0,"total_errors":0,"total_throttles":0,"error_rate":0,"avg_duration":0,"avg_memory":0}}' > function_invocation_health.json
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
echo "Total Executions: $(format_display_value "$TOTAL_EXECUTIONS" "" "0")"
echo "Total Errors: $(format_display_value "$TOTAL_ERRORS" "" "0")"
echo "Total Throttles: $(format_display_value "$TOTAL_THROTTLES" "" "0")"
echo "Overall Error Rate: $(format_display_value "$OVERALL_ERROR_RATE" "%" "0%")"
echo "Issues Found: ${#ISSUES[@]}"
echo ""

if [[ ${#ISSUES[@]} -eq 0 ]]; then
    echo "🎉 All functions are healthy!"
    if [[ $TIME_PERIOD_MINUTES -lt 30 ]]; then
        echo "ℹ️  Note: Short monitoring period ($TIME_PERIOD_MINUTES minutes) - consider using 30+ minutes for better insights"
    fi
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