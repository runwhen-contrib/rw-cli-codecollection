#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AZURE_DEVOPS_PROJECT
#
# This script:
#   1) Gets failed pipeline runs from the last 24 hours
#   2) Analyzes commit history for each failure
#   3) Correlates failures with recent changes
#   4) Provides detailed investigation output
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"

OUTPUT_FILE="pipeline_failure_investigation.json"
investigation_json='[]'

echo "Deep Pipeline Failure Investigation..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Project:      $AZURE_DEVOPS_PROJECT"

# Ensure Azure CLI is logged in and DevOps extension is installed
if ! az extension show --name azure-devops &>/dev/null; then
    echo "Installing Azure DevOps CLI extension..."
    az extension add --name azure-devops --output none
fi

# Configure Azure DevOps CLI defaults
az devops configure --defaults organization="https://dev.azure.com/$AZURE_DEVOPS_ORG" project="$AZURE_DEVOPS_PROJECT" --output none

# Get failed pipeline runs from last 24 hours
echo "Getting failed pipeline runs from last 24 hours..."
from_date=$(date -d "24 hours ago" -u +"%Y-%m-%dT%H:%M:%SZ")

if ! failed_runs=$(az pipelines runs list --query "[?result=='failed' && finishTime >= '$from_date']" --output json 2>failed_runs_err.log); then
    err_msg=$(cat failed_runs_err.log)
    rm -f failed_runs_err.log
    
    echo "ERROR: Could not get failed pipeline runs."
    investigation_json=$(echo "$investigation_json" | jq \
        --arg title "Failed to Get Pipeline Runs" \
        --arg details "$err_msg" \
        --arg severity "3" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber)
        }]')
    echo "$investigation_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f failed_runs_err.log

echo "$failed_runs" > failed_runs.json
failed_count=$(jq '. | length' failed_runs.json)

if [ "$failed_count" -eq 0 ]; then
    echo "No failed pipeline runs found in the last 24 hours."
    investigation_json='[{"title": "No Recent Failures", "details": "No failed pipeline runs found in the last 24 hours", "severity": 1}]'
    echo "$investigation_json" > "$OUTPUT_FILE"
    exit 0
fi

echo "Found $failed_count failed pipeline runs. Investigating..."

# Process each failed run
for ((i=0; i<failed_count; i++)); do
    run_json=$(jq -c ".[${i}]" failed_runs.json)
    
    run_id=$(echo "$run_json" | jq -r '.id')
    pipeline_name=$(echo "$run_json" | jq -r '.name')
    source_version=$(echo "$run_json" | jq -r '.sourceVersion')
    source_branch=$(echo "$run_json" | jq -r '.sourceBranch // "unknown"' | sed 's|refs/heads/||')
    finish_time=$(echo "$run_json" | jq -r '.finishTime')
    
    echo "Investigating failed run: $pipeline_name (ID: $run_id)"
    
    # Get commit details
    if [ "$source_version" != "null" ] && [ -n "$source_version" ]; then
        echo "  Getting commit details for: $source_version"
        if commit_details=$(az repos commit show --commit-id "$source_version" --output json 2>commit_err.log); then
            commit_author=$(echo "$commit_details" | jq -r '.author.name')
            commit_message=$(echo "$commit_details" | jq -r '.comment')
            commit_date=$(echo "$commit_details" | jq -r '.author.date')
            
            # Get commit changes
            changes_count=$(echo "$commit_details" | jq -r '.changes | length')
            changed_files=$(echo "$commit_details" | jq -r '.changes[].item.path' | head -10 | tr '\n' ', ' | sed 's/,$//')
            
            echo "    Commit by: $commit_author"
            echo "    Commit message: $commit_message"
            echo "    Files changed: $changes_count ($changed_files)"
        else
            err_msg=$(cat commit_err.log)
            echo "    Warning: Could not get commit details: $err_msg"
            commit_author="Unknown"
            commit_message="Could not retrieve commit details"
            commit_date="Unknown"
            changes_count=0
            changed_files="Unknown"
        fi
        rm -f commit_err.log
    else
        commit_author="Unknown"
        commit_message="No source version available"
        commit_date="Unknown"
        changes_count=0
        changed_files="Unknown"
    fi
    
    # Get recent commits on the same branch (last 5)
    echo "  Getting recent commit history on branch: $source_branch"
    if recent_commits=$(az repos commit list --branch "$source_branch" --top 5 --output json 2>recent_commits_err.log); then
        recent_commit_summary=$(echo "$recent_commits" | jq -r '.[] | "\(.author.name): \(.comment | split("\n")[0])"' | head -3 | tr '\n' '; ')
    else
        echo "    Warning: Could not get recent commits"
        recent_commit_summary="Could not retrieve recent commits"
    fi
    rm -f recent_commits_err.log
    
    # Get pipeline logs for this specific failure
    echo "  Getting pipeline logs for failed run..."
    if pipeline_logs=$(az pipelines runs show --id "$run_id" --output json 2>pipeline_logs_err.log); then
        pipeline_reason=$(echo "$pipeline_logs" | jq -r '.reason // "Unknown"')
        pipeline_result=$(echo "$pipeline_logs" | jq -r '.result // "Unknown"')
    else
        pipeline_reason="Unknown"
        pipeline_result="Unknown"
    fi
    rm -f pipeline_logs_err.log
    
    # Check for similar recent failures in the same pipeline
    echo "  Checking for pattern of failures..."
    pipeline_id=$(echo "$run_json" | jq -r '.definition.id')
    if similar_failures=$(az pipelines runs list --pipeline-id "$pipeline_id" --query "[?result=='failed' && finishTime >= '$from_date']" --output json 2>similar_err.log); then
        similar_count=$(echo "$similar_failures" | jq '. | length')
    else
        similar_count=0
    fi
    rm -f similar_err.log
    
    # Build investigation summary
    investigation_json=$(echo "$investigation_json" | jq \
        --arg title "Pipeline Failure Investigation: $pipeline_name" \
        --arg pipeline_name "$pipeline_name" \
        --arg run_id "$run_id" \
        --arg source_branch "$source_branch" \
        --arg commit_author "$commit_author" \
        --arg commit_message "$commit_message" \
        --arg commit_date "$commit_date" \
        --arg changes_count "$changes_count" \
        --arg changed_files "$changed_files" \
        --arg recent_commits "$recent_commit_summary" \
        --arg pipeline_reason "$pipeline_reason" \
        --arg similar_count "$similar_count" \
        --arg finish_time "$finish_time" \
        --arg severity "3" \
        '. += [{
           "title": $title,
           "pipeline_name": $pipeline_name,
           "run_id": $run_id,
           "source_branch": $source_branch,
           "commit_author": $commit_author,
           "commit_message": $commit_message,
           "commit_date": $commit_date,
           "changes_count": ($changes_count | tonumber),
           "changed_files": $changed_files,
           "recent_commits": $recent_commits,
           "pipeline_reason": $pipeline_reason,
           "similar_failures_count": ($similar_count | tonumber),
           "finish_time": $finish_time,
           "severity": ($severity | tonumber),
           "details": "Pipeline \($pipeline_name) failed. Last commit by \($commit_author): \($commit_message). \($changes_count) files changed. \($similar_count) similar failures in last 24h.",
           "investigation_summary": "Commit: \($commit_message) by \($commit_author). Files: \($changed_files). Recent activity: \($recent_commits)"
         }]')
done

# Clean up temporary files
rm -f failed_runs.json

# Write final JSON
echo "$investigation_json" > "$OUTPUT_FILE"
echo "Pipeline failure investigation completed. Results saved to $OUTPUT_FILE"

# Output summary to stdout
echo ""
echo "=== INVESTIGATION SUMMARY ==="
echo "$investigation_json" | jq -r '.[] | "Pipeline: \(.pipeline_name)\nAuthor: \(.commit_author)\nMessage: \(.commit_message)\nFiles Changed: \(.changes_count)\nSimilar Failures: \(.similar_failures_count)\n---"' 