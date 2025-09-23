#!/bin/bash

# Exit immediately if a command exits with a non-zero status
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

# Function to fetch job logs with retry logic and proper redirect handling
function fetch_job_logs_with_retry {
    local repo_name="$1"
    local job_id="$2"
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        echo "Attempting to fetch logs for job $job_id (attempt $((retry_count + 1))/$max_retries)..." >&2
        
        # Check log availability first
        local log_status
        log_status=$(curl -sS -L -o /dev/null -w "%{http_code}" "${HEADERS[@]}" \
            -H "Accept: application/vnd.github.v3.raw" \
            "https://api.github.com/repos/$repo_name/actions/jobs/$job_id/logs" 2>/dev/null || echo "000")
        
        case $log_status in
            200|302)
                # Fetch the actual logs
                if job_logs=$(curl -sS -L --max-time 30 "${HEADERS[@]}" \
                    -H "Accept: application/vnd.github.v3.raw" \
                    "https://api.github.com/repos/$repo_name/actions/jobs/$job_id/logs" 2>/dev/null); then
                    
                    local log_size=${#job_logs}
                    if [ $log_size -gt 0 ]; then
                        echo "$job_logs"
                        return 0
                    else
                        echo "Completely empty log response" >&2
                        # Return empty string so extract function can handle it
                        echo ""
                        return 0
                    fi
                else
                    echo "Failed to download logs despite successful status check" >&2
                fi
                ;;
            403)
                echo "Log access forbidden - insufficient permissions"
                return 1
                ;;
            404)
                echo "Logs not found - may have expired"
                return 1
                ;;
            410)
                echo "Logs have been archived or expired"
                return 1
                ;;
            *)
                echo "Log access failed with HTTP $log_status" >&2
                ;;
        esac
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            echo "Retrying in 2 seconds..." >&2
            sleep 2
        fi
    done
    
    echo "Failed to fetch logs after $max_retries attempts"
    return 1
}

# Configuration for log extraction
MAX_LOG_LINES_PER_STEP=${MAX_LOG_LINES_PER_STEP:-50}
LOG_CONTEXT_LINES=${LOG_CONTEXT_LINES:-10}

# Function to extract relevant log lines around failures
function extract_failure_logs {
    local logs="$1"
    local max_lines="$2"
    
    # Look for common failure patterns and extract context around them
    local failure_context=""
    
    # Save logs to local temp file for processing
    local temp_file="./temp_log_$$"
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
    
    # Always include the last N lines as they contain the most relevant failure info
    local log_tail=$(tail -n "$max_lines" "$temp_file")
    if [ -n "$log_tail" ]; then
        local last_lines="\n=== Last $max_lines lines of log ===\n$log_tail"
    else
        local last_lines="\n=== Last $max_lines lines of log ===\n(Log is empty - job likely failed during initialization)"
    fi
    
    # Combine error patterns (if any) with the last lines
    if [ -n "$found_errors" ]; then
        found_errors="$found_errors$last_lines"
    else
        found_errors="$last_lines"
    fi
    
    # Clean up
    rm -f "$temp_file"
    
    echo "$found_errors"
}

# Function to get detailed failure information including logs
function get_failure_details {
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
                        
                        # Try to get logs for this specific job with retry logic
                        echo "Fetching logs for job $job_id (step: $step_name)..." >&2
                        
                        if job_logs=$(fetch_job_logs_with_retry "$repo_name" "$job_id"); then
                            log_size=${#job_logs}
                            echo "Successfully retrieved $log_size bytes of log data" >&2
                            
                            if [ $log_size -eq 0 ]; then
                                detailed_info="$detailed_info\nLog is completely empty - job likely failed before producing any output."
                                detailed_info="$detailed_info\nThis often indicates issues with job setup, permissions, or runner availability."
                            else
                                failure_logs=$(extract_failure_logs "$job_logs" "$MAX_LOG_LINES_PER_STEP")
                                detailed_info="$detailed_info\n$failure_logs"
                            fi
                        else
                            detailed_info="$detailed_info\nFailed to retrieve logs after multiple attempts."
                            detailed_info="$detailed_info\nThis may indicate permission issues, expired logs, or network problems."
                        fi
                        
                        # Rate limit protection
                        sleep 0.3
                        
                    done <<< $(echo "$job_steps" | jq -c '.[]')
                else
                    # Job failed but no specific step failure - get job logs anyway
                    detailed_info="$detailed_info\nJob failed without specific step failures."
                    echo "Job failed without specific step failure, fetching job logs..." >&2
                    
                    if job_logs=$(fetch_job_logs_with_retry "$repo_name" "$job_id"); then
                        failure_logs=$(extract_failure_logs "$job_logs" "$MAX_LOG_LINES_PER_STEP")
                        detailed_info="$detailed_info\n$failure_logs"
                    else
                        detailed_info="$detailed_info\nJob-level logs unavailable - likely workflow setup failure."
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
        
        # Get workflow runs from the repository (sorted by creation date, most recent first)
        runs_json=$(perform_curl "https://api.github.com/repos/$repo_name/actions/runs?status=failure&created=>$date_threshold&per_page=50&sort=created&order=desc" || echo '{"workflow_runs":[]}')
        
        # Check if the response contains workflow runs
        if echo "$runs_json" | jq -e '.workflow_runs' >/dev/null 2>&1; then
            # Extract and format failed workflow runs for this repository
            # Group by workflow name and take only the most recent failure for each workflow
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
                    failure_details: "pending"
                }
            ] | group_by(.workflow_name) | map(.[0])')
            
            # Enhance with detailed failure information (now only most recent per workflow name)
            enhanced_failures="[]"
            while IFS= read -r failure; do
                if [ -n "$failure" ] && [ "$failure" != "null" ]; then
                    run_id=$(echo "$failure" | jq -r '.run_id')
                    workflow_name=$(echo "$failure" | jq -r '.workflow_name')
                    
                    echo "Getting detailed logs for most recent failure of workflow: $workflow_name (run $run_id)..." >&2
                    
                    # Get detailed failure information including logs
                    failure_details=$(get_failure_details "$repo_name" "$run_id" "$workflow_name")
                    
                    # Update the failure object with detailed info (safely handle newlines and special chars)
                    enhanced_failure=$(echo "$failure" | jq --arg details "$failure_details" '.failure_details = $details')
                    # Safely add to array by combining arrays
                    enhanced_failures=$(echo "$enhanced_failures [$enhanced_failure]" | jq -s '.[0] + .[1]')
                fi
            done <<< $(echo "$repo_failures" | jq -c '.[]')
            
            # Merge with all failures
            all_failures=$(echo "$all_failures $enhanced_failures" | jq -s 'add')
        else
            echo "No workflow runs found or access denied for repository: $repo_name" >&2
        fi
        
        # Rate limiting protection (increased due to log fetching)
        sleep 0.5
    fi
done <<< "$repositories"

# Output the results
echo "$all_failures" 