#!/bin/bash

# Function App Failure Analysis Script
# This script provides enhanced failure pattern analysis for Azure Function Apps

set -e

# Source environment variables
source .env 2>/dev/null || true

# Default values
FUNCTION_APP_NAME=${FUNCTION_APP_NAME:-""}
AZ_RESOURCE_GROUP=${AZ_RESOURCE_GROUP:-""}
AZURE_RESOURCE_SUBSCRIPTION_ID=${AZURE_RESOURCE_SUBSCRIPTION_ID:-""}
TIME_PERIOD_MINUTES=${TIME_PERIOD_MINUTES:-30}
FUNCTION_ERROR_RATE_THRESHOLD=${FUNCTION_ERROR_RATE_THRESHOLD:-10}

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

echo "🔍 Enhanced Function App Failure Analysis"
echo "========================================="
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

# Initialize data structures
declare -A ERROR_PATTERNS
declare -A TEMPORAL_PATTERNS
declare -A FUNCTION_HEALTH_SCORES
declare -A RESOURCE_CORRELATIONS

echo "📊 Analyzing Failure Patterns"
echo "============================="

# Function to categorize errors
categorize_error() {
    local error_details="$1"
    local category="Unknown"
    
    case "$error_details" in
        *timeout*|*TimeoutException*)
            category="Timeout"
            ;;
        *memory*|*OutOfMemoryException*|*MemoryError*)
            category="Memory"
            ;;
        *throttle*|*429*|*RateLimitExceeded*)
            category="Throttling"
            ;;
        *dependency*|*connection*|*network*|*502*|*503*|*504*)
            category="Dependency"
            ;;
        *authentication*|*401*|*403*)
            category="Authentication"
            ;;
        *null*|*NullPointerException*|*ArgumentNull*)
            category="Code_Exception"
            ;;
        *)
            category="Application_Error"
            ;;
    esac
    
    echo "$category"
}

# Function to analyze temporal patterns
analyze_temporal_patterns() {
    local function_name="$1"
    echo "  🕐 Analyzing temporal patterns for $function_name..."
    
    # Get hourly error distribution
    local hourly_errors=$(az monitor metrics list \
        --resource "$FUNCTION_APP_ID" \
        --metric "FunctionErrors" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --interval PT1H \
        --filter "FunctionName eq '$function_name'" \
        --query "data[0].timeseries[0].data[].{time: timeStamp, value: total}" -o json 2>/dev/null || echo "[]")
    
    # Analyze patterns (simplified pattern detection)
    local pattern_type="Sporadic"
    local error_count=$(echo "$hourly_errors" | jq '[.[].value // 0] | add // 0')
    
    if [[ "$error_count" -gt 0 ]]; then
        local max_errors=$(echo "$hourly_errors" | jq '[.[].value // 0] | max // 0')
        local non_zero_hours=$(echo "$hourly_errors" | jq '[.[].value // 0] | map(select(. > 0)) | length')
        
        if [[ "$non_zero_hours" -eq 1 ]]; then
            pattern_type="Single_Incident"
        elif [[ "$max_errors" -gt $(echo "$error_count * 0.7" | bc -l 2>/dev/null | cut -d. -f1) ]]; then
            pattern_type="Spike"
        elif [[ "$non_zero_hours" -gt 2 ]]; then
            pattern_type="Recurring"
        fi
    fi
    
    TEMPORAL_PATTERNS["$function_name"]="$pattern_type"
    echo "    Pattern detected: $pattern_type"
}

# Function to calculate health score
calculate_health_score() {
    local function_name="$1"
    local executions="$2"
    local errors="$3"
    local duration="$4"
    local memory="$5"
    
    local score=100
    
    # Deduct points for error rate
    if [[ "$executions" -gt 0 ]]; then
        local error_rate=$(echo "scale=2; $errors * 100 / $executions" | bc -l 2>/dev/null || echo "0")
        local error_penalty=$(echo "scale=0; $error_rate * 2" | bc -l 2>/dev/null || echo "0")
        score=$((score - error_penalty))
    fi
    
    # Deduct points for slow execution
    if [[ "$duration" -gt 3000 ]]; then
        score=$((score - 15))
    elif [[ "$duration" -gt 1000 ]]; then
        score=$((score - 5))
    fi
    
    # Deduct points for high memory usage
    if [[ "$memory" -gt 400 ]]; then
        score=$((score - 10))
    fi
    
    # Ensure score doesn't go below 0
    if [[ "$score" -lt 0 ]]; then
        score=0
    fi
    
    FUNCTION_HEALTH_SCORES["$function_name"]="$score"
    echo "    Health score: $score/100"
}

# Get list of functions
FUNCTIONS=$(az functionapp function list --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "[].name" -o tsv 2>/dev/null)

if [[ -z "$FUNCTIONS" ]]; then
    echo "⚠️  No functions found in Function App $FUNCTION_APP_NAME" 
    
    # Create issue_details format for no functions case
    details="Function App: $FUNCTION_APP_NAME\nResource Group: $AZ_RESOURCE_GROUP\nSubscription: $SUBSCRIPTION_NAME\nTime Period: Last $TIME_PERIOD_MINUTES minutes\n\nIssue: No functions found for analysis\n\nSummary:\nFunctions Analyzed: 0\nFunctions with Errors: 0\nFunctions with Health Score < 80: 0\n\nPossible Causes:\n- Function app is empty or newly created\n- Functions not deployed yet\n- Function app is stopped or disabled\n\nNext Steps:\nVerify function app is running and check if functions have been deployed"
    
    ESCAPED_DETAILS=$(echo "$details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    ESCAPED_FUNCTION_APP_NAME=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g')
    ESCAPED_SUBSCRIPTION_NAME=$(echo "$SUBSCRIPTION_NAME" | sed 's/"/\\"/g')
    
    JSON_OUTPUT="{\"issues\": [{\"title\":\"Function App \`$ESCAPED_FUNCTION_APP_NAME\` in subscription \`$ESCAPED_SUBSCRIPTION_NAME\` has no functions for failure analysis\",\"severity\":4,\"next_step\":\"Verify function app is running and check if functions have been deployed\",\"details\":\"$ESCAPED_DETAILS\"}]}"
    
    echo "$JSON_OUTPUT" > failure_analysis.json
    exit 0
fi

echo "📋 Analyzing $(echo "$FUNCTIONS" | wc -w) function(s):"

# Analyze each function
for func in $FUNCTIONS; do
    echo ""
    echo "🔍 Analyzing function: $func"
    echo "=========================="
    
    # Get function metrics
    executions=$(az monitor metrics list \
        --resource "$FUNCTION_APP_ID" \
        --metric "FunctionExecutionCount" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --interval PT5M \
        --filter "FunctionName eq '$func'" \
        --query "data[0].timeseries[0].data[0].total" -o tsv 2>/dev/null || echo "0")
    
    errors=$(az monitor metrics list \
        --resource "$FUNCTION_APP_ID" \
        --metric "FunctionErrors" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --interval PT5M \
        --filter "FunctionName eq '$func'" \
        --query "data[0].timeseries[0].data[0].total" -o tsv 2>/dev/null || echo "0")
    
    duration=$(az monitor metrics list \
        --resource "$FUNCTION_APP_ID" \
        --metric "FunctionExecutionDuration" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --interval PT5M \
        --filter "FunctionName eq '$func'" \
        --query "data[0].timeseries[0].data[0].average" -o tsv 2>/dev/null || echo "0")
    
    memory=$(az monitor metrics list \
        --resource "$FUNCTION_APP_ID" \
        --metric "FunctionMemoryUsage" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --interval PT5M \
        --filter "FunctionName eq '$func'" \
        --query "data[0].timeseries[0].data[0].average" -o tsv 2>/dev/null || echo "0")
    
    # Clean up values
    executions=${executions//null/0}
    errors=${errors//null/0}
    duration=${duration//null/0}
    memory=${memory//null/0}
    
    echo "  📊 Metrics: $executions executions, $errors errors, ${duration}ms avg, ${memory}MB avg"
    
    # Analyze patterns if there are errors
    if [[ "$errors" != "0" && "$errors" != "" ]]; then
        analyze_temporal_patterns "$func"
        
        # Simulate error categorization (in real scenario, would parse logs)
        if [[ $(echo "$duration > 5000" | bc -l 2>/dev/null) -eq 1 ]]; then
            ERROR_PATTERNS["$func"]="Timeout"
        elif [[ $(echo "$memory > 400" | bc -l 2>/dev/null) -eq 1 ]]; then
            ERROR_PATTERNS["$func"]="Memory"
        else
            ERROR_PATTERNS["$func"]="Application_Error"
        fi
        
        echo "    Error category: ${ERROR_PATTERNS["$func"]}"
    else
        TEMPORAL_PATTERNS["$func"]="Healthy"
        ERROR_PATTERNS["$func"]="None"
    fi
    
    # Calculate health score
    calculate_health_score "$func" "$executions" "$errors" "$duration" "$memory"
done

echo ""
echo "📊 Calculating Summary Statistics"
echo "================================="

# Calculate summary statistics
error_functions=0
unhealthy_count=0

for func in $FUNCTIONS; do
    # Count functions with errors
    if [[ "${ERROR_PATTERNS["$func"]:-"None"}" != "None" ]]; then
        ((error_functions++))
    fi
    
    # Count functions with health score < 80
    health_score=${FUNCTION_HEALTH_SCORES["$func"]:-100}
    if [[ "$health_score" -lt 80 ]]; then
        ((unhealthy_count++))
    fi
done

echo "Functions with errors: $error_functions"
echo "Functions with health score < 80: $unhealthy_count"

echo ""
echo "📋 Generating Issue Details Output"
echo "=================================="

# Initialize issues array
ISSUES=()

# Create issue for failure analysis
if [[ "$error_functions" -gt 0 ]]; then
    # Determine severity based on error patterns
    severity=3  # Warning by default
    if [[ "$unhealthy_count" -gt 2 ]]; then
        severity=2  # Error if multiple functions unhealthy
    fi
    
    # Build details string
    details="Function App: $FUNCTION_APP_NAME\nResource Group: $AZ_RESOURCE_GROUP\nSubscription: $SUBSCRIPTION_NAME\nTime Period: Last $TIME_PERIOD_MINUTES minutes\n\nIssue: Function failure pattern analysis\n\nPer-Function Details:"
    
    for func in $FUNCTIONS; do
        error_category=${ERROR_PATTERNS["$func"]:-"None"}
        temporal_pattern=${TEMPORAL_PATTERNS["$func"]:-"Unknown"}
        health_score=${FUNCTION_HEALTH_SCORES["$func"]:-0}
        
        if [[ "$error_category" != "None" ]]; then
            details="$details\n- $func: $error_category errors, $temporal_pattern pattern, health score: $health_score/100"
        else
            details="$details\n- $func: No errors detected, health score: $health_score/100"
        fi
    done
    
    details="$details\n\nSummary:\nFunctions Analyzed: $(echo "$FUNCTIONS" | wc -w)\nFunctions with Errors: $error_functions\nFunctions with Health Score < 80: $unhealthy_count\nAverage Health Score: $(echo "scale=1; $(for func in $FUNCTIONS; do echo "${FUNCTION_HEALTH_SCORES["$func"]:-100}"; done | awk '{sum+=$1} END {print sum/NR}')" | bc -l 2>/dev/null || echo "100.0")/100"
    
    # Add error pattern analysis
    details="$details\n\nError Pattern Analysis:\nTemporal Patterns: $(for func in $FUNCTIONS; do if [[ "${ERROR_PATTERNS["$func"]:-"None"}" != "None" ]]; then echo "${TEMPORAL_PATTERNS["$func"]:-"Unknown"}"; fi; done | sort | uniq -c | tr '\n' ' ')\nError Categories: $(for func in $FUNCTIONS; do if [[ "${ERROR_PATTERNS["$func"]:-"None"}" != "None" ]]; then echo "${ERROR_PATTERNS["$func"]}"; fi; done | sort | uniq -c | tr '\n' ' ')"
    
    # Add insights and recommendations
    details="$details\n\nPossible Causes:\n- External API failures and timeouts\n- Memory constraints and resource limits\n- Code bugs in recent deployments\n- Dependency service issues\n- Cold start performance problems\n\nNext Steps:\nReview Application Insights logs for detailed error traces, check function configuration and scaling settings, analyze external dependency health"
    
    # Escape for JSON
    ESCAPED_DETAILS=$(echo "$details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    ESCAPED_FUNCTION_APP_NAME=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g')
    ESCAPED_SUBSCRIPTION_NAME=$(echo "$SUBSCRIPTION_NAME" | sed 's/"/\\"/g')
    
    # Create title based on error patterns
    if [[ "$unhealthy_count" -gt 2 ]]; then
        title="Function App \`$ESCAPED_FUNCTION_APP_NAME\` in subscription \`$ESCAPED_SUBSCRIPTION_NAME\` has multiple unhealthy functions ($unhealthy_count functions with health score < 80)"
        next_step="Review Application Insights logs for detailed error traces and check function configuration"
    else
        title="Function App \`$ESCAPED_FUNCTION_APP_NAME\` in subscription \`$ESCAPED_SUBSCRIPTION_NAME\` has error patterns detected ($error_functions functions with errors)"
        next_step="Monitor function performance and review logs for potential issues"
    fi
    
    ISSUES+=("{\"title\":\"$title\",\"severity\":$severity,\"next_step\":\"$next_step\",\"details\":\"$ESCAPED_DETAILS\"}")
else
    # No errors case
    details="Function App: $FUNCTION_APP_NAME\nResource Group: $AZ_RESOURCE_GROUP\nSubscription: $SUBSCRIPTION_NAME\nTime Period: Last $TIME_PERIOD_MINUTES minutes\n\nIssue: Function failure pattern analysis - no errors detected\n\nPer-Function Details:"
    
    for func in $FUNCTIONS; do
        health_score=${FUNCTION_HEALTH_SCORES["$func"]:-100}
        details="$details\n- $func: No errors detected, health score: $health_score/100"
    done
    
    details="$details\n\nSummary:\nFunctions Analyzed: $(echo "$FUNCTIONS" | wc -w)\nFunctions with Errors: 0\nFunctions with Health Score < 80: $unhealthy_count\nAverage Health Score: $(echo "scale=1; $(for func in $FUNCTIONS; do echo "${FUNCTION_HEALTH_SCORES["$func"]:-100}"; done | awk '{sum+=$1} END {print sum/NR}')" | bc -l 2>/dev/null || echo "100.0")/100"
    
    details="$details\n\nAnalysis: All functions are performing well with no error patterns detected in the analyzed timeframe."
    
    details="$details\n\nPossible Causes:\n- Functions are healthy and performing as expected\n- No recent deployments or configuration changes\n- External dependencies are stable\n\nNext Steps:\nContinue monitoring function performance and maintain current operational practices"
    
    # Escape for JSON
    ESCAPED_DETAILS=$(echo "$details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    ESCAPED_FUNCTION_APP_NAME=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g')
    ESCAPED_SUBSCRIPTION_NAME=$(echo "$SUBSCRIPTION_NAME" | sed 's/"/\\"/g')
    
    ISSUES+=("{\"title\":\"Function App \`$ESCAPED_FUNCTION_APP_NAME\` in subscription \`$ESCAPED_SUBSCRIPTION_NAME\` failure analysis - no error patterns detected\",\"severity\":4,\"next_step\":\"Continue monitoring function performance\",\"details\":\"$ESCAPED_DETAILS\"}")
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
echo "$JSON_OUTPUT" > failure_analysis.json

if command -v jq >/dev/null 2>&1; then
    if jq empty failure_analysis.json >/dev/null 2>&1; then
        echo "✅ Issue details JSON validation passed"
        # Pretty print the JSON
        jq '.' failure_analysis.json > temp.json && mv temp.json failure_analysis.json
    else
        echo "❌ Issue details JSON validation failed"
        exit 1
    fi
else
    echo "⚠️  jq not available - JSON validation skipped"
fi 