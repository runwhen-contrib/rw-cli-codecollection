#!/usr/bin/env bash
#set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AZURE_DEVOPS_PROJECT
#
#
# This script:
#   1) Lists all pipelines in the specified Azure DevOps project
#   2) Retrieves logs for each failed run
#   3) Outputs results in JSON format
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"

OUTPUT_FILE="pipeline_logs_issues.json"
TEMP_LOG_FILE="pipeline_log_temp.json"
issues_json='[]'

echo "Analyzing Azure DevOps Pipeline Logs..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Project:      $AZURE_DEVOPS_PROJECT"

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
    
    # Check for failed runs
    for ((j=0; j<run_count; j++)); do
        run_json=$(jq -c ".[${j}]" runs.json)
        
        # Check if run is failed
        run_result=$(echo "$run_json" | jq -r '.result')
        if [[ "$run_result" != "failed" ]]; then
            continue
        fi
        
        run_id=$(echo "$run_json" | jq -r '.id')
        run_name=$(echo "$run_json" | jq -r '.name // "Run #\(.id)"')
        web_url=$(echo "$run_json" | jq -r '.url')
        branch=$(echo "$run_json" | jq -r '.sourceBranch // "unknown"' | sed 's|refs/heads/||')
        
        # Extract project ID from web_url
        project_id=$(echo "$web_url" | grep -o '/[^/]*/[^/]*/_apis' | cut -d'/' -f2)
        
        echo "  Checking failed run: $run_name (ID: $run_id, Branch: $branch)"
        
        # Get all logs for the run using the new API
        if ! all_logs=$(az devops invoke --org "https://dev.azure.com/$AZURE_DEVOPS_ORG" --area pipelines --resource logs --route-parameters project="$AZURE_DEVOPS_PROJECT" pipelineId="$pipeline_id" runId="$run_id" --api-version=7.0 --output json 2>logs_err.log); then
            err_msg=$(cat logs_err.log)
            rm -f logs_err.log
            
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Failed to Get Logs for Run $run_name in Pipeline $pipeline_name" \
                --arg details "$err_msg" \
                --arg severity "3" \
                --arg nextStep "Check if you have sufficient permissions to view pipeline logs." \
                --arg resource_url "$web_url" \
                '. += [{
                   "title": $title,
                   "details": $details,
                   "next_step": $nextStep,
                   "severity": ($severity | tonumber),
                   "resource_url": $resource_url
                 }]')
            continue
        fi
        rm -f logs_err.log
        
        # Save all logs to a file for processing
        echo "$all_logs" > all_logs.json
        
        # Get log with highest line count
        if ! log_info=$(jq -c '.logs[] | {id: .id, lineCount: .lineCount}' all_logs.json | sort -r -k2,2 | head -1); then
            echo "Failed to find logs with line count information"
            continue
        fi
        
        # Extract log ID with highest line count
        log_id=$(echo "$log_info" | jq -r '.id')
        echo "    Selected log ID with highest line count: $log_id"
        
        # Get detailed log content for the selected log
        if ! log_content=$(az devops invoke --org "https://dev.azure.com/$AZURE_DEVOPS_ORG" --area build --resource logs --route-parameters project="$AZURE_DEVOPS_PROJECT" buildId="$run_id" logId="$log_id" --api-version=7.0 --output json --only-show-errors 2>log_content_err.log); then
            echo "      Failed to get log content for log ID $log_id, skipping..."
            continue
        fi
        
        # Save log content to temp file for processing
        echo "$log_content" > "$TEMP_LOG_FILE"
        
        # Extract all log lines and join them with newlines
        log_details=$(jq -r '.value | join("\n")' "$TEMP_LOG_FILE")
        
        # Construct the correct log URL format
        error_log_url="https://dev.azure.com/$AZURE_DEVOPS_ORG/$project_id/_apis/build/builds/$run_id/logs/$log_id"
        
        # Clean up temp files
        rm -f "$TEMP_LOG_FILE" all_logs.json
        
        # Add an issue with the full log content
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Failed Pipeline Run: \`$pipeline_name\` (Branch: \`$branch\`)" \
            --arg details "$log_details" \
            --arg severity "3" \
            --arg nextStep "Review pipeline configuration for \`$pipeline_name\` in project \`$AZURE_DEVOPS_PROJECT\`. Check branch \`$branch\` for recent changes that might have caused the failure." \
            --arg resource_url "$error_log_url" \
            '. += [{
               "title": $title,
               "details": $details,
               "next_step": $nextStep,
               "severity": ($severity | tonumber),
               "resource_url": $resource_url
             }]')
    done
    
    # Clean up runs file
    rm -f runs.json
done

# Clean up pipelines file
rm -f pipelines.json

# Write final JSON
echo "$issues_json" > "$OUTPUT_FILE"
echo "Azure DevOps pipeline log analysis completed. Saved results to $OUTPUT_FILE"
