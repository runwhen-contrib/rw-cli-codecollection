#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AZURE_DEVOPS_PROJECT
#
# This script:
#   1) Lists all pipelines in the specified Azure DevOps project
#   2) Checks for failed runs within the specified time period
#   3) Retrieves logs for each failed run
#   4) Outputs results in JSON format
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"
: "${DAYS_TO_LOOK_BACK:=7}"

OUTPUT_FILE="pipeline_logs_issues.json"
TEMP_LOG_FILE="pipeline_log_temp.json"
issues_json='[]'

echo "Analyzing Azure DevOps Pipeline Logs..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Project:      $AZURE_DEVOPS_PROJECT"
echo "Look Back:    $DAYS_TO_LOOK_BACK days"

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
    
    # Calculate date for filtering runs (in ISO format)
    from_date=$(date -d "$DAYS_TO_LOOK_BACK days ago" -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Get recent pipeline runs
    if ! runs=$(az pipelines runs list --pipeline-id "$pipeline_id" --min-created-time "$from_date" --output json 2>runs_err.log); then
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
    
    # Check for failed runs
    for run in $(echo "${runs}" | jq -c '.[] | select(.result == "failed")'); do
        run_id=$(echo $run | jq -r '.id')
        run_name=$(echo $run | jq -r '.name // "Run #\(.id)"')
        web_url=$(echo $run | jq -r '.url')
        branch=$(echo $run | jq -r '.sourceBranch // "unknown"' | sed 's|refs/heads/||')
        
        echo "  Checking failed run: $run_name (ID: $run_id, Branch: $branch)"
        
        # Get log content
        if ! log_content=$(az pipelines runs show-logs --id "$run_id" --output json 2>log_content_err.log); then
            err_msg=$(cat log_content_err.log)
            rm -f log_content_err.log
            
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
        rm -f log_content_err.log
        
        # Save log content to temp file for processing
        echo "$log_content" > "$TEMP_LOG_FILE"
        
        # Extract error information from logs
        if [[ -s "$TEMP_LOG_FILE" ]]; then
            # Extract error lines from logs
            error_lines=$(jq -r '.[] | select(.line | test("error|exception|failed|Error|Exception|Failed"; "i")) | .line' "$TEMP_LOG_FILE" | head -n 50)
            
            if [[ -n "$error_lines" ]]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Failed Pipeline Run: \`$pipeline_name\` (Branch: \`$branch\`)" \
                    --arg details "$error_lines" \
                    --arg severity "3" \
                    --arg nextStep "Review pipeline configuration for \`$pipeline_name\` in project \`$AZURE_DEVOPS_PROJECT\`. Check branch \`$branch\` for recent changes that might have caused the failure." \
                    --arg resource_url "$web_url" \
                    '. += [{
                       "title": $title,
                       "details": $details,
                       "next_step": $nextStep,
                       "severity": ($severity | tonumber),
                       "resource_url": $resource_url
                     }]')
            fi
            
            # Check for timeout issues
            timeout_lines=$(jq -r '.[] | select(.line | test("timeout|timed out|canceled after|cancelled after"; "i")) | .line' "$TEMP_LOG_FILE")
            if [[ -n "$timeout_lines" ]]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Pipeline Timeout Detected: \`$pipeline_name\` (Branch: \`$branch\`)" \
                    --arg details "$timeout_lines" \
                    --arg severity "3" \
                    --arg nextStep "Increase timeout settings for the pipeline or optimize the build process to complete faster." \
                    --arg resource_url "$web_url" \
                    '. += [{
                       "title": $title,
                       "details": $details,
                       "next_step": $nextStep,
                       "severity": ($severity | tonumber),
                       "resource_url": $resource_url
                     }]')
            fi
            
            # Check for dependency issues
            dependency_lines=$(jq -r '.[] | select(.line | test("package|dependency|module|nuget|npm|pip|maven"; "i") and .line | test("failed|error|not found|missing"; "i")) | .line' "$TEMP_LOG_FILE")
            if [[ -n "$dependency_lines" ]]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Dependency Issues Detected: \`$pipeline_name\` (Branch: \`$branch\`)" \
                    --arg details "$dependency_lines" \
                    --arg severity "3" \
                    --arg nextStep "Check package references and ensure all dependencies are available and correctly versioned." \
                    --arg resource_url "$web_url" \
                    '. += [{
                       "title": $title,
                       "details": $details,
                       "next_step": $nextStep,
                       "severity": ($severity | tonumber),
                       "resource_url": $resource_url
                     }]')
            fi
        fi
        rm -f "$TEMP_LOG_FILE"
    done
done

# Write final JSON
echo "$issues_json" > "$OUTPUT_FILE"
echo "Azure DevOps pipeline log analysis completed. Saved results to $OUTPUT_FILE"
