#!/bin/bash

# Function App Failure Analysis Script - Optimized for Performance
# This script provides enhanced failure pattern analysis for Azure Function Apps

set -e

# Source environment variables
source .env 2>/dev/null || true

# Default values
FUNCTION_APP_NAME=${FUNCTION_APP_NAME:-""}
AZ_RESOURCE_GROUP=${AZ_RESOURCE_GROUP:-""}
AZURE_RESOURCE_SUBSCRIPTION_ID=${AZURE_RESOURCE_SUBSCRIPTION_ID:-""}
TIME_PERIOD_MINUTES=${TIME_PERIOD_MINUTES:-15}  # Reduced from 30 for faster queries
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

echo "🔍 Fast Function App Failure Analysis"
echo "====================================="
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
    details="Function App: $FUNCTION_APP_NAME\nResource Group: $AZ_RESOURCE_GROUP\nSubscription: $SUBSCRIPTION_NAME\nTime Period: Last $TIME_PERIOD_MINUTES minutes\n\nIssue: No functions found for analysis\n\nSummary:\nFunctions Analyzed: 0\nFunctions with Errors: 0\nFunctions with Health Score < 80: 0\n\nPossible Causes:\n- Function app \`$FUNCTION_APP_NAME\` is empty or newly created\n- Functions not deployed to \`$FUNCTION_APP_NAME\` in resource group \`$AZ_RESOURCE_GROUP\`\n- Function app \`$FUNCTION_APP_NAME\` is stopped or disabled\n- Deployment issues preventing function registration\n\nNext Steps:\n1. Check if \`$FUNCTION_APP_NAME\` in resource group \`$AZ_RESOURCE_GROUP\` is running\n2. Verify functions have been deployed to \`$FUNCTION_APP_NAME\`\n3. Review deployment logs for \`$FUNCTION_APP_NAME\`\n4. Check service endpoints and application configuration"
    
    ESCAPED_DETAILS=$(echo "$details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    ESCAPED_FUNCTION_APP_NAME=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g')
    ESCAPED_SUBSCRIPTION_NAME=$(echo "$SUBSCRIPTION_NAME" | sed 's/"/\\"/g')
    
    JSON_OUTPUT="{\"issues\": [{\"title\":\"Function App \`$ESCAPED_FUNCTION_APP_NAME\` in subscription \`$ESCAPED_SUBSCRIPTION_NAME\` has no functions for failure analysis\",\"severity\":4,\"next_step\":\"Check if \`$ESCAPED_FUNCTION_APP_NAME\` in resource group \`$AZ_RESOURCE_GROUP\` is running and verify functions have been deployed\",\"details\":\"$ESCAPED_DETAILS\"}]}"
    
    echo "$JSON_OUTPUT" > failure_analysis.json
    exit 0
fi

echo "📋 Fast analysis of $(echo "$FUNCTIONS" | wc -w) function(s)"

# Initialize data structures
declare -A FUNCTION_EXECUTIONS
declare -A FUNCTION_ERRORS  
declare -A FUNCTION_DURATIONS
declare -A FUNCTION_HEALTH_SCORES
declare -A ERROR_PATTERNS

echo ""
echo "📊 Collecting metrics efficiently..."

# OPTIMIZATION 1: Get execution and error data for ALL functions in fewer calls
echo "  Getting execution counts..."
executions_data=$(az monitor metrics list \
    --resource "$FUNCTION_APP_ID" \
    --metric "FunctionExecutionCount" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --interval PT15M \
    --query "data[0].timeseries[].{function: metadata.FunctionName, value: data[-1].total}" -o json 2>/dev/null || echo "[]")

echo "  Getting error counts..."
errors_data=$(az monitor metrics list \
    --resource "$FUNCTION_APP_ID" \
    --metric "FunctionErrors" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --interval PT15M \
    --query "data[0].timeseries[].{function: metadata.FunctionName, value: data[-1].total}" -o json 2>/dev/null || echo "[]")

echo "  Getting duration data..."
duration_data=$(az monitor metrics list \
    --resource "$FUNCTION_APP_ID" \
    --metric "FunctionExecutionDuration" \
    --start-time "$START_TIME" \
    --end-time "$END_TIME" \
    --interval PT15M \
    --query "data[0].timeseries[].{function: metadata.FunctionName, value: data[-1].average}" -o json 2>/dev/null || echo "[]")

# OPTIMIZATION 2: Process the data efficiently using jq
echo "  Processing data..."

# Parse execution data
for func in $FUNCTIONS; do
    execution_count=$(echo "$executions_data" | jq -r ".[] | select(.function == \"$func\") | .value // 0" | head -1)
    FUNCTION_EXECUTIONS["$func"]=${execution_count:-0}
done

# Parse error data  
for func in $FUNCTIONS; do
    error_count=$(echo "$errors_data" | jq -r ".[] | select(.function == \"$func\") | .value // 0" | head -1)
    FUNCTION_ERRORS["$func"]=${error_count:-0}
done

# Parse duration data
for func in $FUNCTIONS; do
    avg_duration=$(echo "$duration_data" | jq -r ".[] | select(.function == \"$func\") | .value // 0" | head -1)
    FUNCTION_DURATIONS["$func"]=${avg_duration:-0}
done

echo ""
echo "📊 Analyzing failure patterns..."

# OPTIMIZATION 3: Simplified analysis without expensive temporal pattern calls
total_executions=0
total_errors=0
error_functions=0
unhealthy_count=0

for func in $FUNCTIONS; do
    executions=${FUNCTION_EXECUTIONS["$func"]:-0}
    errors=${FUNCTION_ERRORS["$func"]:-0}  
    duration=${FUNCTION_DURATIONS["$func"]:-0}
    
    # Clean values
    executions=${executions//null/0}
    errors=${errors//null/0}
    duration=${duration//null/0}
    
    total_executions=$((total_executions + executions))
    total_errors=$((total_errors + errors))
    
    echo "  📊 $func: $executions executions, $errors errors, ${duration}ms avg"
    
    # Simplified error categorization based on metrics
    if [[ "$errors" -gt 0 ]]; then
        ((error_functions++))
        
        # Categorize based on duration and error patterns
        if [[ $(echo "$duration > 10000" | bc -l 2>/dev/null) -eq 1 ]]; then
            ERROR_PATTERNS["$func"]="Timeout"
        elif [[ $(echo "$duration > 5000" | bc -l 2>/dev/null) -eq 1 ]]; then
            ERROR_PATTERNS["$func"]="Performance"
        else
            ERROR_PATTERNS["$func"]="Application_Error"
        fi
    else
        ERROR_PATTERNS["$func"]="None"
    fi
    
    # Calculate simplified health score
    local score=100
    if [[ "$executions" -gt 0 ]]; then
        local error_rate=$(echo "scale=1; $errors * 100 / $executions" | bc -l 2>/dev/null || echo "0")
        local error_penalty=$(echo "scale=0; $error_rate * 2" | bc -l 2>/dev/null || echo "0")
        score=$((score - error_penalty))
    fi
    
    # Deduct for slow execution
    if [[ $(echo "$duration > 5000" | bc -l 2>/dev/null) -eq 1 ]]; then
        score=$((score - 20))
    elif [[ $(echo "$duration > 2000" | bc -l 2>/dev/null) -eq 1 ]]; then
        score=$((score - 10))
    fi
    
    # Ensure score doesn't go below 0
    if [[ "$score" -lt 0 ]]; then
        score=0
    fi
    
    FUNCTION_HEALTH_SCORES["$func"]="$score"
    
    if [[ "$score" -lt 80 ]]; then
        ((unhealthy_count++))
    fi
done

echo ""
echo "📋 Generating optimized issue details..."

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
        executions=${FUNCTION_EXECUTIONS["$func"]:-0}
        errors=${FUNCTION_ERRORS["$func"]:-0}
        duration=${FUNCTION_DURATIONS["$func"]:-0}
        health_score=${FUNCTION_HEALTH_SCORES["$func"]:-100}
        error_category=${ERROR_PATTERNS["$func"]:-"None"}
        
        if [[ "$errors" -gt 0 ]]; then
            error_rate=$(echo "scale=1; $errors * 100 / $executions" | bc -l 2>/dev/null || echo "0.0")
            details="$details\n- $func: $executions executions, $errors errors (${error_rate}%), ${duration}ms avg, $error_category pattern, health: $health_score/100"
        else
            details="$details\n- $func: $executions executions, no errors, ${duration}ms avg, health: $health_score/100"
        fi
    done
    
    # Calculate overall stats
    if [[ "$total_executions" -gt 0 ]]; then
        overall_error_rate=$(echo "scale=1; $total_errors * 100 / $total_executions" | bc -l 2>/dev/null || echo "0.0")
    else
        overall_error_rate="0.0"
    fi
    
    avg_health_score=$(echo "scale=1; $(for func in $FUNCTIONS; do echo "${FUNCTION_HEALTH_SCORES["$func"]:-100}"; done | awk '{sum+=$1} END {print sum/NR}')" | bc -l 2>/dev/null || echo "100.0")
    
    details="$details\n\nSummary:\nFunctions Analyzed: $(echo "$FUNCTIONS" | wc -w)\nTotal Executions: $total_executions\nTotal Errors: $total_errors\nOverall Error Rate: ${overall_error_rate}%\nFunctions with Errors: $error_functions\nFunctions with Health Score < 80: $unhealthy_count\nAverage Health Score: ${avg_health_score}/100"
    
    # Add error pattern analysis
    timeout_count=$(for func in $FUNCTIONS; do if [[ "${ERROR_PATTERNS["$func"]}" == "Timeout" ]]; then echo "1"; fi; done | wc -l)
    performance_count=$(for func in $FUNCTIONS; do if [[ "${ERROR_PATTERNS["$func"]}" == "Performance" ]]; then echo "1"; fi; done | wc -l)
    app_error_count=$(for func in $FUNCTIONS; do if [[ "${ERROR_PATTERNS["$func"]}" == "Application_Error" ]]; then echo "1"; fi; done | wc -l)
    
    details="$details\n\nError Pattern Analysis:\nTimeout Issues: $timeout_count functions\nPerformance Issues: $performance_count functions\nApplication Errors: $app_error_count functions"
    
    # Add insights and recommendations with entity data
    details="$details\n\nPossible Causes:\n- External API failures affecting \`$FUNCTION_APP_NAME\` functions\n- Performance issues in \`$FUNCTION_APP_NAME\` due to resource constraints\n- Code bugs in recent deployments to resource group \`$AZ_RESOURCE_GROUP\`\n- Dependency service issues impacting function execution\n- Cold start performance problems\n\nNext Steps:\n1. Check Application Insights logs for \`$FUNCTION_APP_NAME\` in resource group \`$AZ_RESOURCE_GROUP\`\n2. Review recent deployments to \`$FUNCTION_APP_NAME\`\n3. Verify application configuration for functions in \`$FUNCTION_APP_NAME\`\n4. Check service endpoints and network connectivity\n5. Review error message details in Application Insights"
    
    # Escape for JSON
    ESCAPED_DETAILS=$(echo "$details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    ESCAPED_FUNCTION_APP_NAME=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g')
    ESCAPED_SUBSCRIPTION_NAME=$(echo "$SUBSCRIPTION_NAME" | sed 's/"/\\"/g')
    
    # Identify failing functions for more specific next steps
    failing_functions=""
    for func in $FUNCTIONS; do
        if [[ "${FUNCTION_ERRORS["$func"]:-0}" -gt 0 ]]; then
            if [[ -n "$failing_functions" ]]; then
                failing_functions="$failing_functions, \`$func\`"
            else
                failing_functions="\`$func\`"
            fi
        fi
    done
    
    # Create title based on error patterns
    if [[ "$unhealthy_count" -gt 2 ]]; then
        title="Function App \`$ESCAPED_FUNCTION_APP_NAME\` in subscription \`$ESCAPED_SUBSCRIPTION_NAME\` has multiple unhealthy functions ($unhealthy_count functions with health score < 80)"
        if [[ -n "$failing_functions" ]]; then
            next_step="Check Application Insights logs for failing functions ($failing_functions) in \`$ESCAPED_FUNCTION_APP_NAME\` resource group \`$AZ_RESOURCE_GROUP\` and review recent deployments"
        else
            next_step="Check Application Insights logs for \`$ESCAPED_FUNCTION_APP_NAME\` in resource group \`$AZ_RESOURCE_GROUP\` and review function configuration"
        fi
    else
        title="Function App \`$ESCAPED_FUNCTION_APP_NAME\` in subscription \`$ESCAPED_SUBSCRIPTION_NAME\` has error patterns detected ($error_functions functions with errors)"
        if [[ -n "$failing_functions" ]]; then
            next_step="Review error message details for functions ($failing_functions) in Application Insights for \`$ESCAPED_FUNCTION_APP_NAME\` resource group \`$AZ_RESOURCE_GROUP\`"
        else
            next_step="Review error message details in Application Insights for \`$ESCAPED_FUNCTION_APP_NAME\` and verify application configuration in resource group \`$AZ_RESOURCE_GROUP\`"
        fi
    fi
    
    ISSUES+=("{\"title\":\"$title\",\"severity\":$severity,\"next_step\":\"$next_step\",\"details\":\"$ESCAPED_DETAILS\"}")
else
    # No errors case
    avg_health_score=$(echo "scale=1; $(for func in $FUNCTIONS; do echo "${FUNCTION_HEALTH_SCORES["$func"]:-100}"; done | awk '{sum+=$1} END {print sum/NR}')" | bc -l 2>/dev/null || echo "100.0")
    
    details="Function App: $FUNCTION_APP_NAME\nResource Group: $AZ_RESOURCE_GROUP\nSubscription: $SUBSCRIPTION_NAME\nTime Period: Last $TIME_PERIOD_MINUTES minutes\n\nIssue: Function failure pattern analysis - no errors detected\n\nPer-Function Details:"
    
    for func in $FUNCTIONS; do
        executions=${FUNCTION_EXECUTIONS["$func"]:-0}
        duration=${FUNCTION_DURATIONS["$func"]:-0}
        health_score=${FUNCTION_HEALTH_SCORES["$func"]:-100}
        details="$details\n- $func: $executions executions, no errors, ${duration}ms avg, health: $health_score/100"
    done
    
    details="$details\n\nSummary:\nFunctions Analyzed: $(echo "$FUNCTIONS" | wc -w)\nTotal Executions: $total_executions\nTotal Errors: 0\nFunctions with Errors: 0\nFunctions with Health Score < 80: $unhealthy_count\nAverage Health Score: ${avg_health_score}/100"
    
    details="$details\n\nAnalysis: All functions are performing well with no error patterns detected in the analyzed timeframe.\n\nPossible Causes:\n- Functions in \`$FUNCTION_APP_NAME\` are healthy and performing as expected\n- No recent deployments or configuration changes causing issues\n- External dependencies are stable\n- Resource constraints are within acceptable limits\n\nNext Steps:\n1. Check service endpoints for \`$FUNCTION_APP_NAME\` and verify network connectivity from resource group \`$AZ_RESOURCE_GROUP\`\n2. Continue monitoring function performance\n3. Maintain current operational practices\n4. Review Application Insights for \`$FUNCTION_APP_NAME\` for any warnings"
    
    # Escape for JSON
    ESCAPED_DETAILS=$(echo "$details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    ESCAPED_FUNCTION_APP_NAME=$(echo "$FUNCTION_APP_NAME" | sed 's/"/\\"/g')
    ESCAPED_SUBSCRIPTION_NAME=$(echo "$SUBSCRIPTION_NAME" | sed 's/"/\\"/g')
    
    ISSUES+=("{\"title\":\"Function App \`$ESCAPED_FUNCTION_APP_NAME\` in subscription \`$ESCAPED_SUBSCRIPTION_NAME\` failure analysis - no error patterns detected\",\"severity\":4,\"next_step\":\"Check service endpoints for \`$ESCAPED_FUNCTION_APP_NAME\` and verify network connectivity from resource group \`$AZ_RESOURCE_GROUP\`\",\"details\":\"$ESCAPED_DETAILS\"}")
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
        echo "✅ Fast failure analysis completed successfully"
        # Pretty print the JSON
        jq '.' failure_analysis.json > temp.json && mv temp.json failure_analysis.json
    else
        echo "❌ Issue details JSON validation failed"
        exit 1
    fi
else
    echo "⚠️  jq not available - JSON validation skipped"
fi

echo ""
echo "🎯 Fast Analysis Summary"
echo "======================="
echo "Functions Analyzed: $(echo "$FUNCTIONS" | wc -w)"
echo "Total Executions: $total_executions"
echo "Total Errors: $total_errors"
echo "Functions with Errors: $error_functions"
echo "Functions with Health Score < 80: $unhealthy_count"

if [[ "$total_executions" -gt 0 ]]; then
    overall_error_rate=$(echo "scale=1; $total_errors * 100 / $total_executions" | bc -l 2>/dev/null || echo "0.0")
    echo "Overall Error Rate: ${overall_error_rate}%"
fi

echo ""
echo "✅ Optimized failure analysis completed in seconds instead of minutes!" 