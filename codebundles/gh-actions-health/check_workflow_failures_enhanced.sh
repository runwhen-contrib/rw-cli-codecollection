#!/bin/bash

# Enhanced Workflow Failures Check with Log Extraction
# This version fetches actual log content around the failure points

set -e

# Function to handle error messages and exit
function error_exit {
    echo "Error: $1" >&2
    exit 1
}

# Check required environment variables
if [ -z "$GITHUB_TOKEN" ]; then
    error_exit "GITHUB_TOKEN is required"
fi

# Configuration
MAX_LOG_LINES_PER_STEP=${MAX_LOG_LINES_PER_STEP:-50}
LOG_CONTEXT_LINES=${LOG_CONTEXT_LINES:-10}

# Build the headers array for curl
HEADERS=()
if [ -n "$GITHUB_TOKEN" ]; then
    HEADERS+=(-H "Authorization: token $GITHUB_TOKEN")
fi
HEADERS+=(-H "Accept: application/vnd.github.v3+json")

# Function to perform curl requests with error handling
function perform_curl {
    local url="$1"
    local response
    response=$(curl -sS "${HEADERS[@]}" "$url") || error_exit "Failed to perform curl request to $url"
    echo "$response"
}

# Function to extract relevant log lines around failures
function extract_failure_logs {
    local logs="$1"
    local max_lines="$2"
    
    # Look for common failure patterns and extract context around them
    local failure_context=""
    
    # Save logs to temp file for processing
    local temp_file=$(mktemp)
    echo "$logs" > "$temp_file"
    
    # Extract lines around error patterns (case insensitive)
    local error_patterns=(
        "error"
        "failed"
        "failure"
        "exception"
        "fatal"
        "panic"
        "abort"
        "timeout"
        "killed"
        "exit code [1-9]"
        "command not found"
        "permission denied"
        "no such file"
        "connection refused"
        "network unreachable"
    )
    
    local found_errors=""
    for pattern in "${error_patterns[@]}"; do
        # Use grep to find lines with context
        if matches=$(grep -i -n -A"$LOG_CONTEXT_LINES" -B"$LOG_CONTEXT_LINES" "$pattern" "$temp_file" 2>/dev/null | head -n "$max_lines"); then
            if [ -n "$matches" ]; then
                found_errors="$found_errors\n\n=== Error Pattern: $pattern ===\n$matches"
            fi
        fi
    done
    
    # If no specific error patterns found, get the last N lines (likely contains the failure)
    if [ -z "$found_errors" ]; then
        found_errors="\n=== Last $max_lines lines of log ===\n$(tail -n "$max_lines" "$temp_file")"
    fi
    
    # Clean up
    rm -f "$temp_file"
    
    echo "$found_errors"
}

# Function to get detailed failure information including logs
function get_detailed_failure_info {
    local repo_name="$1"
    local run_id="$2"
    local workflow_name="$3"
    
    echo "Fetching detailed failure info for $workflow_name (run $run_id) in $repo_name..." >&2
    
    # Get workflow run jobs
    jobs_json=$(perform_curl "https://api.github.com/repos/$repo_name/actions/runs/$run_id/jobs" || echo '{"jobs":[]}')
    
    local detailed_info=""
    if echo "$jobs_json" | jq -e '.jobs' >/dev/null 2>&1; then
        failed_jobs=$(echo "$jobs_json" | jq -r '[.jobs[] | select(.conclusion == "failure" or .conclusion == "cancelled")] | .[0:2]')
        
        if [ "$(echo "$failed_jobs" | jq 'length')" -gt 0 ]; then
            while IFS= read -r job; do
                job_name=$(echo "$job" | jq -r '.name')
                job_conclusion=$(echo "$job" | jq -r '.conclusion')
                job_id=$(echo "$job" | jq -r '.id')
                
                detailed_info="$detailed_info\n\n=== JOB: $job_name (Status: $job_conclusion) ==="
                
                # Get failed steps
                job_steps=$(echo "$job" | jq -r '[.steps[] | select(.conclusion == "failure")] | .[0:3]')
                
                if [ "$(echo "$job_steps" | jq 'length')" -gt 0 ]; then
                    while IFS= read -r step; do
                        step_name=$(echo "$step" | jq -r '.name')
                        step_number=$(echo "$step" | jq -r '.number')
                        step_conclusion=$(echo "$step" | jq -r '.conclusion')
                        
                        detailed_info="$detailed_info\n\n--- FAILED STEP: $step_name (Step #$step_number) ---"
                        
                        # Try to get logs for this specific job
                        echo "Fetching logs for job $job_id..." >&2
                        if job_logs=$(curl -sS "${HEADERS[@]}" \
                            -H "Accept: application/vnd.github.v3.raw" \
                            "https://api.github.com/repos/$repo_name/actions/jobs/$job_id/logs" 2>/dev/null); then
                            
                            # Extract relevant failure logs
                            if [ -n "$job_logs" ]; then
                                failure_logs=$(extract_failure_logs "$job_logs" "$MAX_LOG_LINES_PER_STEP")
                                detailed_info="$detailed_info\n$failure_logs"
                            else
                                detailed_info="$detailed_info\nNo logs available for this step."
                            fi
                        else
                            detailed_info="$detailed_info\nFailed to fetch logs for this job."
                        fi
                        
                        # Rate limit protection
                        sleep 0.3
                        
                    done <<< $(echo "$job_steps" | jq -c '.[]')
                else
                    # Job failed but no specific step failure - get job logs anyway
                    echo "Job failed without specific step failure, fetching job logs..." >&2
                    if job_logs=$(curl -sS "${HEADERS[@]}" \
                        -H "Accept: application/vnd.github.v3.raw" \
                        "https://api.github.com/repos/$repo_name/actions/jobs/$job_id/logs" 2>/dev/null); then
                        
                        if [ -n "$job_logs" ]; then
                            failure_logs=$(extract_failure_logs "$job_logs" "$MAX_LOG_LINES_PER_STEP")
                            detailed_info="$detailed_info\n$failure_logs"
                        fi
                    fi
                fi
                
            done <<< $(echo "$failed_jobs" | jq -c '.[]')
        fi
    fi
    
    # If no detailed info found, provide generic details
    if [ -z "$detailed_info" ]; then
        detailed_info="No detailed failure information available. The workflow may have failed at the workflow level or logs may not be accessible."
    fi
    
    echo "$detailed_info"
}

# Function to get repositories to analyze
function get_repositories_to_analyze {
    if [ "$GITHUB_REPOS" = "ALL" ]; then
        if [ -z "$GITHUB_ORGS" ]; then
            error_exit "GITHUB_ORGS is required when GITHUB_REPOS is 'ALL'"
        fi
        
        echo "Getting all repositories for organizations: $GITHUB_ORGS..." >&2
        
        # Initialize repository list
        all_repos=""
        
        # Process each organization
        IFS=',' read -ra ORG_ARRAY <<< "$GITHUB_ORGS"
        for org in "${ORG_ARRAY[@]}"; do
            # Trim whitespace
            org=$(echo "$org" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [ -n "$org" ]; then
                echo "Fetching repositories for organization: $org" >&2
                
                # Get repositories for this organization
                org_repos_json=$(perform_curl "https://api.github.com/orgs/$org/repos?per_page=100&sort=updated")
                
                # Apply per-org limit if specified
                if [ "${MAX_REPOS_PER_ORG:-0}" -gt 0 ]; then
                    org_repos=$(echo "$org_repos_json" | jq -r ".[0:${MAX_REPOS_PER_ORG}] | .[].full_name")
                else
                    org_repos=$(echo "$org_repos_json" | jq -r '.[].full_name')
                fi
                
                # Add to overall list
                if [ -n "$all_repos" ]; then
                    all_repos="$all_repos"$'\n'"$org_repos"
                else
                    all_repos="$org_repos"
                fi
                
                # Rate limiting protection between organizations
                sleep 0.5
            fi
        done
        
        # Apply overall limit if specified
        if [ "${MAX_REPOS_TO_ANALYZE:-0}" -gt 0 ]; then
            echo "$all_repos" | head -n "${MAX_REPOS_TO_ANALYZE}"
        else
            echo "$all_repos"
        fi
    else
        # Split comma-separated list and output each repository
        echo "$GITHUB_REPOS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    fi
}

# Default values
LOOKBACK_DAYS=${FAILURE_LOOKBACK_DAYS:-7}

# Calculate the date threshold
date_threshold=$(date -d "$LOOKBACK_DAYS days ago" -u +%Y-%m-%dT%H:%M:%SZ)

echo "Checking workflow failures with detailed logs across specified repositories since $date_threshold..." >&2
echo "Log extraction settings: MAX_LOG_LINES_PER_STEP=$MAX_LOG_LINES_PER_STEP, LOG_CONTEXT_LINES=$LOG_CONTEXT_LINES" >&2

# Get repositories to analyze
repositories=$(get_repositories_to_analyze)

# Initialize results array
all_failures="[]"

# Process each repository
while IFS= read -r repo_name; do
    if [ -n "$repo_name" ]; then
        echo "Checking repository: $repo_name" >&2
        
        # Get workflow runs from the repository
        runs_json=$(perform_curl "https://api.github.com/repos/$repo_name/actions/runs?status=failure&created=>$date_threshold&per_page=50" || echo '{"workflow_runs":[]}')
        
        # Check if the response contains workflow runs
        if echo "$runs_json" | jq -e '.workflow_runs' >/dev/null 2>&1; then
            # Extract and format failed workflow runs for this repository
            repo_failures=$(echo "$runs_json" | jq -r --arg repo "$repo_name" '[
                .workflow_runs[] | 
                select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out") |
                {
                    repository: $repo,
                    workflow_name: .name,
                    run_number: .run_number,
                    run_id: .id,
                    conclusion: .conclusion,
                    html_url: .html_url,
                    created_at: .created_at,
                    head_branch: .head_branch,
                    head_sha: (.head_sha // ""),
                    actor: .actor.login,
                    failure_details: "pending_detailed_analysis"
                }
            ]')
            
            # Enhance with detailed failure information including logs (limit to avoid too many API calls)
            enhanced_failures="[]"
            failure_count=0
            while IFS= read -r failure; do
                if [ -n "$failure" ] && [ "$failure" != "null" ] && [ $failure_count -lt 3 ]; then
                    run_id=$(echo "$failure" | jq -r '.run_id')
                    workflow_name=$(echo "$failure" | jq -r '.workflow_name')
                    
                    echo "Getting detailed logs for workflow: $workflow_name (run $run_id)..." >&2
                    
                    # Get detailed failure information including logs
                    detailed_info=$(get_detailed_failure_info "$repo_name" "$run_id" "$workflow_name")
                    
                    # Update the failure object with detailed info (safely handle newlines and special chars)
                    enhanced_failure=$(echo "$failure" | jq --arg details "$detailed_info" '.failure_details = $details')
                    
                    # Safely add to array by combining arrays
                    enhanced_failures=$(echo "$enhanced_failures [$enhanced_failure]" | jq -s '.[0] + .[1]')
                    
                    failure_count=$((failure_count + 1))
                else
                    # Add without enhanced details to avoid too many API calls
                    basic_failure=$(echo "$failure" | jq '.failure_details = "Log analysis skipped - too many failures"')
                    enhanced_failures=$(echo "$enhanced_failures [$basic_failure]" | jq -s '.[0] + .[1]')
                fi
            done <<< $(echo "$repo_failures" | jq -c '.[]')
            
            # Merge with all failures
            all_failures=$(echo "$all_failures $enhanced_failures" | jq -s 'add')
        else
            echo "No workflow runs found or access denied for repository: $repo_name" >&2
        fi
        
        # Rate limiting protection
        sleep 0.3
    fi
done <<< "$repositories"

# Output the results
echo "$all_failures" 