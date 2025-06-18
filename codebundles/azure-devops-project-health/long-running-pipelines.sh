#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AZURE_DEVOPS_PROJECT
#
# OPTIONAL ENV VARS:
#   DURATION_THRESHOLD - Threshold in minutes or hours (e.g., "60m" or "2h") for long-running pipelines (default: "60m")
#
# This script:
#   1) Lists all pipelines in the specified Azure DevOps project
#   2) Checks for runs that exceed the specified duration threshold
#   3) Outputs results in JSON format
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"
: "${DURATION_THRESHOLD:=1m}"
: "${AUTH_TYPE:=service_principal}"

OUTPUT_FILE="long_running_pipelines.json"
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
            echo "Invalid duration format. Use format like '60m' or '2h'" >&2
            exit 1
            ;;
    esac
}

THRESHOLD_MINUTES=$(convert_to_minutes "$DURATION_THRESHOLD")

echo "Analyzing Azure DevOps Pipeline Durations..."
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

# Setup authentication
if [ "$AUTH_TYPE" = "service_principal" ]; then
    echo "Using service principal authentication..."
    # Service principal authentication is handled by Azure CLI login
elif [ "$AUTH_TYPE" = "pat" ]; then
    if [ -z "${AZURE_DEVOPS_PAT:-}" ]; then
        echo "ERROR: AZURE_DEVOPS_PAT must be set when AUTH_TYPE=pat"
        exit 1
    fi
    echo "Using PAT authentication..."
    echo "$AZURE_DEVOPS_PAT" | az devops login --organization "https://dev.azure.com/$AZURE_DEVOPS_ORG"
else
    echo "ERROR: Invalid AUTH_TYPE. Must be 'service_principal' or 'pat'"
    exit 1
fi

# Get list of pipelines
echo "Retrieving pipelines in project..."
if ! pipelines=$(az pipelines list --output json 2>pipelines_err.log); then
    err_msg=$(cat pipelines_err.log)
    rm -f pipelines_err.log
    
    echo "ERROR: Could not list pipelines."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Failed to List Pipelines" \
        --arg details "$err_msg" \
        --arg severity "3" \
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

# Save pipelines to a file to avoid subshell issues
echo "$pipelines" > pipelines.json

# Get the number of pipelines
pipeline_count=$(jq '. | length' pipelines.json)

# Process each pipeline using a for loop instead of pipe to while
for ((i=0; i<pipeline_count; i++)); do
    pipeline_json=$(jq -c ".[${i}]" pipelines.json)
    
    # Extract values from JSON using jq
    pipeline_id=$(echo "$pipeline_json" | jq -r '.id')
    pipeline_name=$(echo "$pipeline_json" | jq -r '.name')
    
    echo "Processing Pipeline: $pipeline_name (ID: $pipeline_id)"
    
    # # Calculate date for filtering runs (in ISO format)
    # from_date=$(date -d "$DAYS_TO_LOOK_BACK days ago" -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Get recent pipeline runs
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
    
    # Save runs to a file to avoid subshell issues
    echo "$runs" > runs.json
    
    # Get the number of runs
    run_count=$(jq '. | length' runs.json)
    
    # Check for currently running pipelines
    for ((j=0; j<run_count; j++)); do
        run_json=$(jq -c ".[${j}]" runs.json)
        
        # Check if run is in progress
        run_state=$(echo "$run_json" | jq -r '.status')
        if [[ "$run_state" != "inProgress" ]]; then
            continue
        fi
        
        run_id=$(echo "$run_json" | jq -r '.id')
        run_name=$(echo "$run_json" | jq -r '.name // "Run #\(.id)"')
        web_url=$(echo "$run_json" | jq -r '.url')
        branch=$(echo "$run_json" | jq -r '.sourceBranch // "unknown"' | sed 's|refs/heads/||')
        created_date=$(echo "$run_json" | jq -r '.startTime')
        
        # Calculate run duration in minutes
        created_timestamp=$(date -d "$created_date" +%s)
        current_timestamp=$(date +%s)
        duration_seconds=$((current_timestamp - created_timestamp))
        duration_minutes=$((duration_seconds / 60))
        
        # Format duration for display
        if [ $duration_minutes -ge 1440 ]; then
            days=$((duration_minutes / 1440))
            hours=$(((duration_minutes % 1440) / 60))
            mins=$((duration_minutes % 60))
            formatted_duration="${days}d ${hours}h ${mins}m"
        elif [ $duration_minutes -ge 60 ]; then
            hours=$((duration_minutes / 60))
            mins=$((duration_minutes % 60))
            formatted_duration="${hours}h ${mins}m"
        else
            formatted_duration="${duration_minutes}m"
        fi
        
        echo "  Checking running pipeline: $run_name (ID: $run_id, Branch: $branch, Duration: $formatted_duration)"
        
        # Check if duration exceeds threshold
        if [ $duration_minutes -ge $THRESHOLD_MINUTES ]; then
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Long Running Pipeline: \`$pipeline_name\` (Branch: \`$branch\`)" \
                --arg details "Pipeline has been running for $formatted_duration (exceeds threshold of $THRESHOLD_MINUTES minutes)" \
                --arg severity "3" \
                --arg nextStep "Investigate why pipeline \`$pipeline_name\` in project \`$AZURE_DEVOPS_PROJECT\` is taking longer than expected. Check for resource constraints or inefficient tasks." \
                --arg resource_url "$web_url" \
                --arg duration "$formatted_duration" \
                --arg duration_minutes "$duration_minutes" \
                --arg pipeline_id "$pipeline_id" \
                --arg run_id "$run_id" \
                --arg branch "$branch" \
                '. += [{
                   "title": $title,
                   "details": $details,
                   "next_step": $nextStep,
                   "severity": ($severity | tonumber),
                   "resource_url": $resource_url,
                   "duration": $duration,
                   "duration_minutes": ($duration_minutes | tonumber),
                   "pipeline_id": $pipeline_id,
                   "run_id": $run_id,
                   "branch": $branch
                 }]')
        fi
    done
    
    # Also check for completed runs that took longer than the threshold
    for ((j=0; j<run_count; j++)); do
        run_json=$(jq -c ".[${j}]" runs.json)
        
        # Check if run is completed
        run_state=$(echo "$run_json" | jq -r '.status')
        if [[ "$run_state" != "completed" ]]; then
            continue
        fi
        
        run_id=$(echo "$run_json" | jq -r '.id')
        run_name=$(echo "$run_json" | jq -r '.name // "Run #\(.id)"')
        web_url=$(echo "$run_json" | jq -r '.url')
        branch=$(echo "$run_json" | jq -r '.sourceBranch // "unknown"' | sed 's|refs/heads/||')
        
        # Get start and finish times
        start_time=$(echo "$run_json" | jq -r '.startTime')
        finish_time=$(echo "$run_json" | jq -r '.finishTime')
        
        # Check if both times are valid
        if [ "$start_time" != "null" ] && [ -n "$start_time" ] && [ "$finish_time" != "null" ] && [ -n "$finish_time" ]; then
            # Convert ISO timestamps to Unix timestamps using date
            start_timestamp=$(date -d "$start_time" +%s 2>/dev/null || echo 0)
            finish_timestamp=$(date -d "$finish_time" +%s 2>/dev/null || echo 0)
            
            # Calculate duration in seconds
            if [ "$start_timestamp" -gt 0 ] && [ "$finish_timestamp" -gt 0 ]; then
                duration_seconds=$((finish_timestamp - start_timestamp))
            else
                duration_seconds=0
                echo "  Warning: Could not parse timestamps for run $run_id"
            fi
        else
            duration_seconds=0
            echo "  Warning: Missing start or finish time for run $run_id"
        fi
        
        duration_minutes=$((duration_seconds / 60))
        
        # Format duration for display
        if [ $duration_minutes -ge 1440 ]; then
            days=$((duration_minutes / 1440))
            hours=$(((duration_minutes % 1440) / 60))
            mins=$((duration_minutes % 60))
            formatted_duration="${days}d ${hours}h ${mins}m"
        elif [ $duration_minutes -ge 60 ]; then
            hours=$((duration_minutes / 60))
            mins=$((duration_minutes % 60))
            formatted_duration="${hours}h ${mins}m"
        else
            formatted_duration="${duration_minutes}m"
        fi
        
        # Check if duration exceeds threshold
        if [ $duration_minutes -ge $THRESHOLD_MINUTES ]; then
            echo "  Found long-running completed pipeline: $run_name (ID: $run_id, Branch: $branch, Duration: $formatted_duration)"
            
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Long Running Completed Pipeline: \`$pipeline_name\` (Branch: \`$branch\`)" \
                --arg details "Pipeline run completed in $formatted_duration (exceeds threshold of $THRESHOLD_MINUTES minutes)" \
                --arg severity "2" \
                --arg nextStep "Review pipeline \`$pipeline_name\` in project \`$AZURE_DEVOPS_PROJECT\` for optimization opportunities. Consider parallelizing tasks or upgrading agent resources." \
                --arg resource_url "$web_url" \
                --arg duration "$formatted_duration" \
                --arg duration_minutes "$duration_minutes" \
                --arg pipeline_id "$pipeline_id" \
                --arg run_id "$run_id" \
                --arg branch "$branch" \
                '. += [{
                   "title": $title,
                   "details": $details,
                   "next_step": $nextStep,
                   "severity": ($severity | tonumber),
                   "resource_url": $resource_url,
                   "duration": $duration,
                   "duration_minutes": ($duration_minutes | tonumber),
                   "pipeline_id": $pipeline_id,
                   "run_id": $run_id,
                   "branch": $branch
                 }]')
        fi
    done
    
    # Clean up runs file
    rm -f runs.json
done

# Clean up pipelines file
rm -f pipelines.json

# Write final JSON
echo "$issues_json" > "$OUTPUT_FILE"
echo "Azure DevOps long-running pipeline analysis completed. Saved results to $OUTPUT_FILE"
