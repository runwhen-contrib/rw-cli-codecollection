#!/bin/bash

# Workflow Failures Check with Graceful Log Access Fallback
# This version handles cases where log access is not available

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
ENABLE_LOG_EXTRACTION=${ENABLE_LOG_EXTRACTION:-true}

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

# Function to test log access permissions
function test_log_access {
    local repo_name="$1"
    local run_id="$2"
    
    # Try to get jobs for this run
    local jobs_json
    jobs_json=$(perform_curl "https://api.github.com/repos/$repo_name/actions/runs/$run_id/jobs" 2>/dev/null || echo '{"jobs":[]}')
    
    if echo "$jobs_json" | jq -e '.jobs[0].id' >/dev/null 2>&1; then
        local job_id
        job_id=$(echo "$jobs_json" | jq -r '.jobs[0].id')
        
        # Test log access with a HEAD request
        local http_code
        http_code=$(curl -sS -o /dev/null -w "%{http_code}" "${HEADERS[@]}" \
            -H "Accept: application/vnd.github.v3.raw" \
            "https://api.github.com/repos/$repo_name/actions/jobs/$job_id/logs" 2>/dev/null || echo "000")
        
        case $http_code in
            200)
                echo "accessible"
                ;;
            403)
                echo "forbidden"
                ;;
            404)
                echo "not_found"
                ;;
            *)
                echo "unknown"
                ;;
        esac
    else
        echo "no_jobs"
    fi
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

# Function to get enhanced failure information
function get_enhanced_failure_info {
    local repo_name="$1"
    local run_id="$2"
    local workflow_name="$3"
    
    echo "Analyzing failure for $workflow_name (run $run_id) in $repo_name..." >&2
    
    # Get workflow run jobs
    local jobs_json
    jobs_json=$(perform_curl "https://api.github.com/repos/$repo_name/actions/runs/$run_id/jobs" || echo '{"jobs":[]}')
    
    local detailed_info=""
    if echo "$jobs_json" | jq -e '.jobs' >/dev/null 2>&1; then
        local failed_jobs
        failed_jobs=$(echo "$jobs_json" | jq -r '[.jobs[] | select(.conclusion == "failure" or .conclusion == "cancelled")] | .[0:2]')
        
        if [ "$(echo "$failed_jobs" | jq 'length')" -gt 0 ]; then
            while IFS= read -r job; do
                local job_name job_conclusion job_id job_started_at job_completed_at
                job_name=$(echo "$job" | jq -r '.name')
                job_conclusion=$(echo "$job" | jq -r '.conclusion')
                job_id=$(echo "$job" | jq -r '.id')
                job_started_at=$(echo "$job" | jq -r '.started_at // "unknown"')
                job_completed_at=$(echo "$job" | jq -r '.completed_at // "unknown"')
                
                detailed_info="$detailed_info\n\n=== JOB: $job_name (Status: $job_conclusion) ==="
                detailed_info="$detailed_info\nJob ID: $job_id"
                detailed_info="$detailed_info\nStarted: $job_started_at"
                detailed_info="$detailed_info\nCompleted: $job_completed_at"
                
                # Get failed steps with more details
                local job_steps
                job_steps=$(echo "$job" | jq -r '[.steps[] | select(.conclusion == "failure")] | .[0:3]')
                
                if [ "$(echo "$job_steps" | jq 'length')" -gt 0 ]; then
                    while IFS= read -r step; do
                        local step_name step_number step_conclusion step_started_at step_completed_at
                        step_name=$(echo "$step" | jq -r '.name')
                        step_number=$(echo "$step" | jq -r '.number')
                        step_conclusion=$(echo "$step" | jq -r '.conclusion')
                        step_started_at=$(echo "$step" | jq -r '.started_at // "unknown"')
                        step_completed_at=$(echo "$step" | jq -r '.completed_at // "unknown"')
                        
                        detailed_info="$detailed_info\n\n--- FAILED STEP: $step_name (Step #$step_number) ---"
                        detailed_info="$detailed_info\nStep Status: $step_conclusion"
                        detailed_info="$detailed_info\nStep Started: $step_started_at"
                        detailed_info="$detailed_info\nStep Completed: $step_completed_at"
                        
                        # Try to get logs if enabled and accessible
                        if [ "$ENABLE_LOG_EXTRACTION" = "true" ]; then
                            echo "Attempting to fetch logs for job $job_id..." >&2
                            if job_logs=$(curl -sS "${HEADERS[@]}" \
                                -H "Accept: application/vnd.github.v3.raw" \
                                "https://api.github.com/repos/$repo_name/actions/jobs/$job_id/logs" 2>/dev/null); then
                                
                                # Check if we got actual logs
                                if [ -n "$job_logs" ] && [ "$job_logs" != "null" ]; then
                                    echo "Successfully retrieved logs for job $job_id" >&2
                                    failure_logs=$(extract_failure_logs "$job_logs" "$MAX_LOG_LINES_PER_STEP")
                                    detailed_info="$detailed_info\n$failure_logs"
                                else
                                    detailed_info="$detailed_info\nLogs are empty or unavailable for this job."
                                fi
                            else
                                detailed_info="$detailed_info\nLog access failed - token may lack 'actions:read' permission."
                                detailed_info="$detailed_info\nTo enable log extraction, ensure your GitHub token has 'actions:read' scope."
                            fi
                        else
                            detailed_info="$detailed_info\nLog extraction disabled (set ENABLE_LOG_EXTRACTION=true to enable)."
                        fi
                        
                        # Rate limit protection
                        sleep 0.3
                        
                    done <<< $(echo "$job_steps" | jq -c '.[]')
                else
                    # Job failed but no specific step failure - try to get job logs anyway
                    detailed_info="$detailed_info\nJob failed without specific step failures."
                    
                    if [ "$ENABLE_LOG_EXTRACTION" = "true" ]; then
                        echo "Job failed without specific step failure, attempting to fetch job logs..." >&2
                        if job_logs=$(curl -sS "${HEADERS[@]}" \
                            -H "Accept: application/vnd.github.v3.raw" \
                            "https://api.github.com/repos/$repo_name/actions/jobs/$job_id/logs" 2>/dev/null); then
                            
                            if [ -n "$job_logs" ]; then
                                failure_logs=$(extract_failure_logs "$job_logs" "$MAX_LOG_LINES_PER_STEP")
                                detailed_info="$detailed_info\n$failure_logs"
                            fi
                        fi
                    fi
                fi
                
            done <<< $(echo "$failed_jobs" | jq -c '.[]')
        fi
    fi
    
    # If no detailed info found, provide helpful guidance
    if [ -z "$detailed_info" ]; then
        detailed_info="No detailed failure information available.\n\nPossible reasons:\n"
        detailed_info="$detailed_info- The workflow may have failed at the workflow level\n"
        detailed_info="$detailed_info- Logs may not be accessible with current token permissions\n"
        detailed_info="$detailed_info- Logs may have expired or been deleted\n\n"
        detailed_info="$detailed_info To get detailed logs, ensure your GitHub token has 'actions:read' permission.\n"
        detailed_info="$detailed_info View the full logs at: https://github.com/$repo_name/actions/runs/$run_id"
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

echo "Checking workflow failures with enhanced analysis across specified repositories since $date_threshold..." >&2
echo "Configuration: LOG_EXTRACTION=$ENABLE_LOG_EXTRACTION, MAX_LINES=$MAX_LOG_LINES_PER_STEP, CONTEXT=$LOG_CONTEXT_LINES" >&2

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
                    failure_details: "pending_analysis"
                }
            ]')
            
            # Enhance with detailed failure information (limit to avoid too many API calls)
            enhanced_failures="[]"
            failure_count=0
            while IFS= read -r failure; do
                if [ -n "$failure" ] && [ "$failure" != "null" ] && [ $failure_count -lt 3 ]; then
                    run_id=$(echo "$failure" | jq -r '.run_id')
                    workflow_name=$(echo "$failure" | jq -r '.workflow_name')
                    
                    echo "Analyzing workflow: $workflow_name (run $run_id)..." >&2
                    
                    # Get enhanced failure information
                    failure_details=$(get_enhanced_failure_info "$repo_name" "$run_id" "$workflow_name")
                    
                    # Update the failure object with detailed info (safely handle newlines and special chars)
                    enhanced_failure=$(echo "$failure" | jq --arg details "$failure_details" '.failure_details = $details')
                    
                    # Safely add to array by combining arrays
                    enhanced_failures=$(echo "$enhanced_failures [$enhanced_failure]" | jq -s '.[0] + .[1]')
                    
                    failure_count=$((failure_count + 1))
                else
                    # Add without enhanced details to avoid too many API calls
                    basic_failure=$(echo "$failure" | jq '.failure_details = "Analysis skipped - too many failures in repository"')
                    enhanced_failures=$(echo "$enhanced_failures [$basic_failure]" | jq -s '.[0] + .[1]')
                fi
            done <<< $(echo "$repo_failures" | jq -c '.[]')
            
            # Merge with all failures
            all_failures=$(echo "$all_failures $enhanced_failures" | jq -s 'add')
        else
            echo "No workflow runs found or access denied for repository: $repo_name" >&2
        fi
        
        # Rate limiting protection (increased due to potential log fetching)
        sleep 0.5
    fi
done <<< "$repositories"

# Output the results
echo "$all_failures" 