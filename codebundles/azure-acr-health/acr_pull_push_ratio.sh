#!/bin/bash

set -o pipefail

# Environment variables
SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID:-}
RESOURCE_GROUP=${AZ_RESOURCE_GROUP:-}
ACR_NAME=${ACR_NAME:-}
LOG_WORKSPACE_ID=${LOG_WORKSPACE_ID:-}
TIME_PERIOD_HOURS=${TIME_PERIOD_HOURS:-24}
PULL_SUCCESS_THRESHOLD=${PULL_SUCCESS_THRESHOLD:-95}
PUSH_SUCCESS_THRESHOLD=${PUSH_SUCCESS_THRESHOLD:-98}

ISSUES_FILE="pull_push_ratio_issues.json"
echo '[]' > "$ISSUES_FILE"

add_issue() {
    local title="$1"
    local severity="$2"
    local expected="$3"
    local actual="$4"
    local details="$5"
    local next_steps="$6"
    local reproduce_hint="$7"
    
    # Escape JSON characters properly
    details=$(echo "$details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    next_steps=$(echo "$next_steps" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    reproduce_hint=$(echo "$reproduce_hint" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    
    local issue="{\"title\":\"$title\",\"severity\":$severity,\"expected\":\"$expected\",\"actual\":\"$actual\",\"details\":\"$details\",\"next_steps\":\"$next_steps\",\"reproduce_hint\":\"$reproduce_hint\"}"
    jq ". += [${issue}]" "$ISSUES_FILE" > temp.json && mv temp.json "$ISSUES_FILE"
}

# Validate required environment variables
if [ -z "$SUBSCRIPTION_ID" ] || [ -z "$RESOURCE_GROUP" ] || [ -z "$ACR_NAME" ]; then
    missing_vars=()
    [ -z "$SUBSCRIPTION_ID" ] && missing_vars+=("AZURE_SUBSCRIPTION_ID")
    [ -z "$RESOURCE_GROUP" ] && missing_vars+=("AZ_RESOURCE_GROUP")
    [ -z "$ACR_NAME" ] && missing_vars+=("ACR_NAME")
    
    add_issue \
        "Missing required environment variables" \
        4 \
        "All required environment variables should be set" \
        "Missing variables: ${missing_vars[*]}" \
        "Required variables: AZURE_SUBSCRIPTION_ID, AZ_RESOURCE_GROUP, ACR_NAME" \
        "Set the missing environment variables and retry" \
        "Check environment variable configuration"
    
    echo "❌ Missing required environment variables: ${missing_vars[*]}" >&2
    
    # Still output JSON even when there are missing variables
    cat "$ISSUES_FILE"
    exit 0
fi

echo "🔍 Analyzing ACR pull/push success ratio for registry: $ACR_NAME" >&2
echo "⏰ Time period: last $TIME_PERIOD_HOURS hours" >&2

# Set subscription context
az account set --subscription "$SUBSCRIPTION_ID" 2>/dev/null || {
    add_issue \
        "Failed to set Azure subscription context" \
        3 \
        "Should be able to set subscription context" \
        "Failed to set subscription $SUBSCRIPTION_ID" \
        "Subscription ID: $SUBSCRIPTION_ID" \
        "Verify subscription ID \`$SUBSCRIPTION_ID\` and Azure authentication for resource group \`$RESOURCE_GROUP\`" \
        "az account set --subscription $SUBSCRIPTION_ID"
    echo "❌ Failed to set subscription context" >&2
    cat "$ISSUES_FILE"
    exit 0
}

# Get ACR resource ID for metrics queries
acr_resource_id=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query "id" -o tsv 2>/dev/null)
if [ -z "$acr_resource_id" ]; then
    add_issue \
        "Failed to retrieve ACR resource ID" \
        3 \
        "Should be able to retrieve ACR resource information" \
        "ACR resource ID not found" \
        "Registry: $ACR_NAME, Resource Group: $RESOURCE_GROUP" \
        "Verify ACR name \`$ACR_NAME\`, resource group \`$RESOURCE_GROUP\`, and permissions" \
        "az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP"
    echo "❌ Failed to retrieve ACR resource ID" >&2
    cat "$ISSUES_FILE"
    exit 0
fi

echo "📊 ACR Resource ID: $acr_resource_id" >&2

# Calculate time range
end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
start_time=$(date -u -d "$TIME_PERIOD_HOURS hours ago" +"%Y-%m-%dT%H:%M:%SZ")

echo "📅 Analyzing from $start_time to $end_time" >&2

# Initialize counters
total_pulls=0
successful_pulls=0
total_pushes=0
successful_pushes=0

# Function to query Azure Monitor metrics
query_acr_metrics() {
    local metric_name="$1"
    local dimension_filter="$2"
    
    az monitor metrics list \
        --resource "$acr_resource_id" \
        --metric "$metric_name" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --interval "PT1H" \
        --aggregation "Total" \
        --output json 2>/dev/null
}

# Try to get pull metrics
echo "🔽 Querying pull metrics..." >&2
pull_metrics=$(query_acr_metrics "PullCount" || echo "[]")
if [ -n "$pull_metrics" ] && [ "$pull_metrics" != "[]" ]; then
    # Extract total pulls
    total_pulls=$(echo "$pull_metrics" | jq -r '
        [.value[].timeseries[]?.data[]?.total // 0] | add // 0
    ' 2>/dev/null || echo "0")
    echo "📥 Total pulls: $total_pulls" >&2
else
    echo "⚠️ No pull metrics available for the specified time period" >&2
fi

# Try to get push metrics  
echo "🔼 Querying push metrics..." >&2
push_metrics=$(query_acr_metrics "PushCount" || echo "[]")
if [ -n "$push_metrics" ] && [ "$push_metrics" != "[]" ]; then
    # Extract total pushes
    total_pushes=$(echo "$push_metrics" | jq -r '
        [.value[].timeseries[]?.data[]?.total // 0] | add // 0
    ' 2>/dev/null || echo "0")
    echo "📤 Total pushes: $total_pushes" >&2
else
    echo "⚠️ No push metrics available for the specified time period" >&2
fi

# If we have Log Analytics workspace, try to get more detailed information
if [ -n "$LOG_WORKSPACE_ID" ]; then
    echo "📋 Querying Log Analytics for detailed ACR events..." >&2
    
    # Query for container registry repository events
    log_query='ContainerRegistryRepositoryEvents
    | where TimeGenerated >= datetime('$start_time') and TimeGenerated <= datetime('$end_time')
    | where Repository != ""
    | summarize 
        TotalPulls = countif(OperationName == "Pull"),
        SuccessfulPulls = countif(OperationName == "Pull" and ResultType == 0),
        TotalPushes = countif(OperationName == "Push"),  
        SuccessfulPushes = countif(OperationName == "Push" and ResultType == 0),
        FailedPulls = countif(OperationName == "Pull" and ResultType != 0),
        FailedPushes = countif(OperationName == "Push" and ResultType != 0)
    | extend 
        PullSuccessRate = round(100.0 * SuccessfulPulls / nullif(TotalPulls, 0), 2),
        PushSuccessRate = round(100.0 * SuccessfulPushes / nullif(TotalPushes, 0), 2)'
    
    log_results=$(az monitor log-analytics query \
        --workspace "$LOG_WORKSPACE_ID" \
        --analytics-query "$log_query" \
        --output json 2>/dev/null || echo "[]")
    
    if [ -n "$log_results" ] && [ "$log_results" != "[]" ]; then
        echo "📊 Log Analytics results available" >&2
        
        # Extract detailed metrics from Log Analytics
        la_total_pulls=$(echo "$log_results" | jq -r '.tables[0].rows[0][0] // 0')
        la_successful_pulls=$(echo "$log_results" | jq -r '.tables[0].rows[0][1] // 0')
        la_total_pushes=$(echo "$log_results" | jq -r '.tables[0].rows[0][2] // 0')
        la_successful_pushes=$(echo "$log_results" | jq -r '.tables[0].rows[0][3] // 0')
        la_failed_pulls=$(echo "$log_results" | jq -r '.tables[0].rows[0][4] // 0')
        la_failed_pushes=$(echo "$log_results" | jq -r '.tables[0].rows[0][5] // 0')
        la_pull_success_rate=$(echo "$log_results" | jq -r '.tables[0].rows[0][6] // 0')
        la_push_success_rate=$(echo "$log_results" | jq -r '.tables[0].rows[0][7] // 0')
        
        # Use Log Analytics data if available (more accurate)
        if [ "$la_total_pulls" -gt 0 ]; then
            total_pulls=$la_total_pulls
            successful_pulls=$la_successful_pulls
        fi
        
        if [ "$la_total_pushes" -gt 0 ]; then
            total_pushes=$la_total_pushes
            successful_pushes=$la_successful_pushes
        fi
        
        echo "📊 Detailed metrics from Log Analytics:" >&2
        echo "   Total pulls: $total_pulls (successful: $successful_pulls, failed: $la_failed_pulls)" >&2
        echo "   Total pushes: $total_pushes (successful: $successful_pushes, failed: $la_failed_pushes)" >&2
        echo "   Pull success rate: $la_pull_success_rate%" >&2
        echo "   Push success rate: $la_push_success_rate%" >&2
    else
        echo "⚠️ No detailed Log Analytics data available" >&2
        echo "   This could indicate:" >&2
        echo "   - No ACR activity in the specified time period" >&2
        echo "   - Log Analytics workspace not properly configured" >&2
        echo "   - Insufficient permissions to query logs" >&2
    fi
else
    echo "ℹ️ LOG_WORKSPACE_ID not provided - using basic metrics only" >&2
    add_issue \
        "Log Analytics workspace not configured" \
        4 \
        "Log Analytics should be configured for detailed ACR monitoring" \
        "LOG_WORKSPACE_ID environment variable not set" \
        "Without Log Analytics, only basic metrics are available" \
        "Configure Log Analytics workspace for ACR \`$ACR_NAME\` and set LOG_WORKSPACE_ID environment variable for detailed ACR event analysis in resource group \`$RESOURCE_GROUP\`" \
        "Set LOG_WORKSPACE_ID environment variable"
fi

# Calculate success rates
pull_success_rate=0
push_success_rate=0

if [ "$total_pulls" -gt 0 ]; then
    pull_success_rate=$(echo "scale=2; ($successful_pulls * 100) / $total_pulls" | bc -l)
    echo "📥 Pull success rate: $pull_success_rate%" >&2
    
    # Check pull success rate threshold
    if (( $(echo "$pull_success_rate < $PULL_SUCCESS_THRESHOLD" | bc -l) )); then
        failed_pulls=$((total_pulls - successful_pulls))
        add_issue \
            "Low pull success rate: $pull_success_rate%" \
            2 \
            "Pull success rate should be above ${PULL_SUCCESS_THRESHOLD}%" \
            "Current pull success rate is $pull_success_rate% ($successful_pulls successful, $failed_pulls failed out of $total_pulls total)" \
            "Total pulls: $total_pulls, Successful: $successful_pulls, Failed: $failed_pulls, Success rate: $pull_success_rate%, Threshold: ${PULL_SUCCESS_THRESHOLD}%" \
            "Investigate pull failures for ACR \`$ACR_NAME\` in logs, check network connectivity, authentication issues, and image availability in resource group \`$RESOURCE_GROUP\`" \
            "az monitor log-analytics query --workspace $LOG_WORKSPACE_ID --analytics-query \"ContainerRegistryRepositoryEvents | where OperationName == 'Pull' and ResultType != 0\""
    fi
else
    echo "ℹ️ No pull operations detected in the specified time period" >&2
    add_issue \
        "No pull operations detected" \
        4 \
        "Some pull activity expected for active registries" \
        "No pull operations found in the last $TIME_PERIOD_HOURS hours" \
        "Time period: $TIME_PERIOD_HOURS hours, Registry: $ACR_NAME" \
        "Verify that applications are actively using ACR \`$ACR_NAME\`, or adjust the time period for analysis in resource group \`$RESOURCE_GROUP\`" \
        "Check application configurations and registry usage patterns"
fi

if [ "$total_pushes" -gt 0 ]; then
    push_success_rate=$(echo "scale=2; ($successful_pushes * 100) / $total_pushes" | bc -l)
    echo "📤 Push success rate: $push_success_rate%" >&2
    
    # Check push success rate threshold
    if (( $(echo "$push_success_rate < $PUSH_SUCCESS_THRESHOLD" | bc -l) )); then
        failed_pushes=$((total_pushes - successful_pushes))
        add_issue \
            "Low push success rate: $push_success_rate%" \
            2 \
            "Push success rate should be above ${PUSH_SUCCESS_THRESHOLD}%" \
            "Current push success rate is $push_success_rate% ($successful_pushes successful, $failed_pushes failed out of $total_pushes total)" \
            "Total pushes: $total_pushes, Successful: $successful_pushes, Failed: $failed_pushes, Success rate: $push_success_rate%, Threshold: ${PUSH_SUCCESS_THRESHOLD}%" \
            "Investigate push failures for ACR \`$ACR_NAME\` in logs, check authentication, network connectivity, storage quotas, and repository permissions in resource group \`$RESOURCE_GROUP\`" \
            "az monitor log-analytics query --workspace $LOG_WORKSPACE_ID --analytics-query \"ContainerRegistryRepositoryEvents | where OperationName == 'Push' and ResultType != 0\""
    fi
else
    echo "ℹ️ No push operations detected in the specified time period" >&2
    add_issue \
        "No push operations detected" \
        4 \
        "Some push activity expected for active development" \
        "No push operations found in the last $TIME_PERIOD_HOURS hours" \
        "Time period: $TIME_PERIOD_HOURS hours, Registry: $ACR_NAME" \
        "Verify that CI/CD pipelines are actively pushing to ACR \`$ACR_NAME\`, or adjust the time period for analysis in resource group \`$RESOURCE_GROUP\`" \
        "Check CI/CD pipeline configurations and deployment processes"
fi

# Additional analysis if both operations are present
if [ "$total_pulls" -gt 0 ] && [ "$total_pushes" -gt 0 ]; then
    pull_push_ratio=$(echo "scale=2; $total_pulls / $total_pushes" | bc -l)
    echo "⚖️ Pull to Push ratio: $pull_push_ratio:1" >&2
    
    # Analyze ratio patterns
    if (( $(echo "$pull_push_ratio > 100" | bc -l) )); then
        echo "📈 High pull-to-push ratio detected - indicates good registry usage" >&2
    elif (( $(echo "$pull_push_ratio < 1" | bc -l) )); then
        add_issue \
            "Unusual pull-to-push ratio: more pushes than pulls" \
            4 \
            "Typically expect more pulls than pushes in healthy registries" \
            "Pull-to-push ratio is $pull_push_ratio:1 (more pushes than pulls)" \
            "Pulls: $total_pulls, Pushes: $total_pushes, Ratio: $pull_push_ratio:1" \
            "Review ACR \`$ACR_NAME\` usage patterns - this might indicate testing scenarios or unusual deployment patterns in resource group \`$RESOURCE_GROUP\`" \
            "Analyze application deployment and testing patterns"
    fi
fi

# Generate portal URLs
resource_id="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ContainerRegistry/registries/$ACR_NAME"
portal_url="https://portal.azure.com/#@/resource$resource_id"

# Output portal URLs to stderr so they don't interfere with JSON parsing
echo "" >&2
echo "🔗 Portal URLs:" >&2
echo "   ACR Metrics: ${portal_url}/metrics" >&2
echo "   ACR Logs: ${portal_url}/logs" >&2
if [ -n "$LOG_WORKSPACE_ID" ]; then
    echo "   Log Analytics: https://portal.azure.com/#@/resource/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.OperationalInsights/workspaces/$(basename $LOG_WORKSPACE_ID)" >&2
fi

echo "" >&2
echo "✅ Pull/Push ratio analysis complete" >&2

# Display summary to stderr
issue_count=$(jq '. | length' "$ISSUES_FILE")
echo "📋 Issues found: $issue_count" >&2

if [ "$issue_count" -gt 0 ]; then
    echo "" >&2
    echo "Issues:" >&2
    jq -r '.[] | "  - \(.title) (Severity: \(.severity))"' "$ISSUES_FILE" >&2
fi

# Output the JSON file content to stdout for Robot Framework (this should be the ONLY stdout output)
cat "$ISSUES_FILE"
