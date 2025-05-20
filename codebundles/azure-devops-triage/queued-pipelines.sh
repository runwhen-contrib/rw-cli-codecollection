#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AZURE_DEVOPS_PROJECT
#
# OPTIONAL ENV VARS:
#   QUEUE_THRESHOLD - Threshold in minutes or hours (e.g., "10m" or "1h") for queued pipelines (default: "10m")
#
# This script:
#   1) Lists all pipelines in the specified Azure DevOps project
#   2) Checks for runs that are queued longer than the specified threshold
#   3) Outputs results in JSON format
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"
: "${QUEUE_THRESHOLD:=10m}"

OUTPUT_FILE="queued_pipelines.json"
issues_json='[]'

# Convert duration threshold to minutes
convert_to_minutes() {
    local threshold=$1
    local number=$(echo "$threshold" | sed -E 's/[^0-9]//g')
    local unit=$(echo "$threshold" | sed -E 's/[0-9]//g')
    
    case $unit in
        m|min|mins)
            echo $number
            ;;
        h|hr|hrs|hour|hours)
            echo $((number * 60))
            ;;
        *)
            echo "Invalid duration format. Use format like '10m' or '1h'" >&2
            exit 1
            ;;
    esac
}

THRESHOLD_MINUTES=$(convert_to_minutes "$QUEUE_THRESHOLD")

echo "Analyzing Azure DevOps Queued Pipelines..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Project:      $AZURE_DEVOPS_PROJECT"
echo "Threshold:    $THRESHOLD_MINUTES minutes"

# Ensure Azure CLI is logged in and DevOps extension is installed
if ! az extension show --name azure-devops &>/dev/null; then
    echo "Installing Azure DevOps CLI extension..."
    az extension add --name azure-devops --output none
fi

# Configure Azure DevOps CLI defaults
az devops configure --defaults organization="https://dev.azure.com/$AZURE_DEVOPS_ORG" project="$AZURE_DEVOPS_PROJECT" --output none

# Get list of pipelines
echo "Retrieving pipelines in project..."
if ! pipelines=$(az pipelines list --output json 2>pipelines_err.log); then
    err_msg=$(cat pipelines_err.log)
    rm -f pipelines_err.log
    
    echo "ERROR: Could not list pipelines."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Failed to List Pipelines" \
        --arg details "$err_msg" \
        --arg severity "4" \
        --arg nextStep "Check if the project exists and you have the right permissions." \
        '. += [{
           "title": $title,
           "details": $details,
           "next_step": $nextStep,
           "severity": ($severity | tonumber)
        }]')
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f pipelines_err.log

# Process each pipeline
for row in $(echo "${pipelines}" | jq -c '.[]'); do
    pipeline_id=$(echo $row | jq -r '.id')
    pipeline_name=$(echo $row | jq -r '.name')
    
    echo "Processing Pipeline: $pipeline_name (ID: $pipeline_id)"
    
    # Get queued runs for this pipeline
    if ! runs=$(az pipelines runs list --pipeline-id "$pipeline_id" --output json 2>runs_err.log); then
        err_msg=$(cat runs_err.log)
        rm -f runs_err.log
        
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Failed to List Runs for Pipeline $pipeline_name" \
            --arg details "$err_msg" \
            --arg severity "3" \
            --arg nextStep "Check if you have sufficient permissions to view pipeline runs." \
            '. += [{
               "title": $title,
               "details": $details,
               "next_step": $nextStep,
               "severity": ($severity | tonumber)
             }]')
        continue
    fi
    rm -f runs_err.log
    
    # Check for queued runs
    for run in $(echo "${runs}" | jq -c '.[] | select(.state == "notStarted")'); do
        run_id=$(echo $run | jq -r '.id')
        run_name=$(echo $run | jq -r '.name // "Run #\(.id)"')
        web_url=$(echo $run | jq -r '.url')
        branch=$(echo $run | jq -r '.sourceBranch // "unknown"' | sed 's|refs/heads/||')
        created_date=$(echo $run | jq -r '.createdDate')
        
        # Calculate queue time in minutes
        created_timestamp=$(date -d "$created_date" +%s)
        current_timestamp=$(date +%s)
        queue_seconds=$((current_timestamp - created_timestamp))
        queue_minutes=$((queue_seconds / 60))
        
        # Format queue time for display
        if [ $queue_minutes -ge 1440 ]; then
            days=$((queue_minutes / 1440))
            hours=$(((queue_minutes % 1440) / 60))
            mins=$((queue_minutes % 60))
            formatted_queue_time="${days}d ${hours}h ${mins}m"
        elif [ $queue_minutes -ge 60 ]; then
            hours=$((queue_minutes / 60))
            mins=$((queue_minutes % 60))
            formatted_queue_time="${hours}h ${mins}m"
        else
            formatted_queue_time="${queue_minutes}m"
        fi
        
        echo "  Checking queued pipeline: $run_name (ID: $run_id, Branch: $branch, Queue Time: $formatted_queue_time)"
        
        # Check if queue time exceeds threshold
        if [ $queue_minutes -ge $THRESHOLD_MINUTES ]; then
            # Try to get more details about why it's queued
            queue_reason="Unknown"
            if ! run_details=$(az pipelines runs show --id "$run_id" --output json 2>/dev/null); then
                queue_reason="Could not retrieve detailed information"
            else
                # Extract queue position if available
                queue_position=$(echo "$run_details" | jq -r '.queuePosition // "Unknown"')
                if [ "$queue_position" != "null" ] && [ "$queue_position" != "Unknown" ]; then
                    queue_reason="Queue position: $queue_position"
                fi
                
                # Try to extract any waiting reason
                waiting_reason=$(echo "$run_details" | jq -r '.reason // "Unknown"')
                if [ "$waiting_reason" != "null" ] && [ "$waiting_reason" != "Unknown" ]; then
                    queue_reason="$queue_reason, Reason: $waiting_reason"
                fi
            fi
            
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Pipeline Queued Too Long: \`$pipeline_name\` (Branch: \`$branch\`)" \
                --arg details "Pipeline has been queued for $formatted_queue_time (exceeds threshold of $THRESHOLD_MINUTES minutes). $queue_reason" \
                --arg severity "3" \
                --arg nextStep "Check agent pool capacity and availability. Consider adding more agents or optimizing pipeline concurrency limits." \
                --arg resource_url "$web_url" \
                --arg queue_time "$formatted_queue_time" \
                --arg queue_minutes "$queue_minutes" \
                --arg pipeline_id "$pipeline_id" \
                --arg run_id "$run_id" \
                --arg branch "$branch" \
                --arg queue_reason "$queue_reason" \
                '. += [{
                   "title": $title,
                   "details": $details,
                   "next_step": $nextStep,
                   "severity": ($severity | tonumber),
                   "resource_url": $resource_url,
                   "queue_time": $queue_time,
                   "queue_minutes": ($queue_minutes | tonumber),
                   "pipeline_id": $pipeline_id,
                   "run_id": $run_id,
                   "branch": $branch,
                   "queue_reason": $queue_reason
                 }]')
        fi
    done
done

# Get agent pools to check for capacity issues
echo "Checking agent pools for capacity issues..."
if ! pools=$(az pipelines pool list --output json 2>/dev/null); then
    echo "WARNING: Could not list agent pools to check capacity."
else
    # Process each pool to check capacity
    for pool in $(echo "${pools}" | jq -c '.[]'); do
        pool_id=$(echo $pool | jq -r '.id')
        pool_name=$(echo $pool | jq -r '.name')
        
        # Skip Microsoft-hosted pools as we can't manage their capacity
        is_hosted=$(echo $pool | jq -r '.isHosted // false')
        if [ "$is_hosted" = "true" ]; then
            continue
        }
        
        # Get agents in the pool
        if ! agents=$(az pipelines agent list --pool-id "$pool_id" --output json 2>/dev/null); then
            continue
        fi
        
        # Count total and busy agents
        total_agents=$(echo "$agents" | jq 'length')
        busy_agents=$(echo "$agents" | jq '[.[] | select(.status == "online" and .enabled == true and .assignedRequest != null)] | length')
        
        # If all agents are busy, report capacity issue
        if [ "$total_agents" -gt 0 ] && [ "$busy_agents" -eq "$total_agents" ]; then
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Agent Pool \`$pool_name\` at Full Capacity" \
                --arg details "All $total_agents agents in pool are currently busy. This may be causing pipeline queuing." \
                --arg severity "3" \
                --arg nextStep "Consider adding more agents to pool \`$pool_name\` to reduce queue times." \
                '. += [{
                   "title": $title,
                   "details": $details,
                   "next_step": $nextStep,
                   "severity": ($severity | tonumber)
                 }]')
        fi
    done
fi

# Write final JSON
echo "$issues_json" > "$OUTPUT_FILE"
echo "Azure DevOps queued pipeline analysis completed. Saved results to $OUTPUT_FILE"