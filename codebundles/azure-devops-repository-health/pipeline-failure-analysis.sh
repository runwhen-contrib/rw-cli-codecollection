#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AZURE_DEVOPS_PROJECT
#   AZURE_DEVOPS_REPO
#   ANALYSIS_DAYS (optional, default: 7)
#
# This script:
#   1) Analyzes recent pipeline failures for the repository
#   2) Identifies patterns in failures that might indicate application issues
#   3) Checks for deployment failures and CI/CD issues
#   4) Provides actionable insights for troubleshooting
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"
: "${AZURE_DEVOPS_REPO:?Must set AZURE_DEVOPS_REPO}"
: "${ANALYSIS_DAYS:=7}"

OUTPUT_FILE="pipeline_failure_analysis.json"
failures_json='[]'

echo "Analyzing Pipeline Failures for Troubleshooting..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Project: $AZURE_DEVOPS_PROJECT"
echo "Repository: $AZURE_DEVOPS_REPO"
echo "Analysis Period: Last $ANALYSIS_DAYS days"

# Ensure Azure CLI is logged in and DevOps extension is installed
if ! az extension show --name azure-devops &>/dev/null; then
    echo "Installing Azure DevOps CLI extension..."
    az extension add --name azure-devops --output none
fi

# Configure Azure DevOps CLI defaults
az devops configure --defaults organization="https://dev.azure.com/$AZURE_DEVOPS_ORG" project="$AZURE_DEVOPS_PROJECT" --output none

# Calculate date range for analysis
from_date=$(date -d "$ANALYSIS_DAYS days ago" -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Analyzing pipeline failures since: $from_date"

# Get pipelines for this repository
echo "Getting pipelines for repository..."
if ! pipelines=$(az pipelines list --repository "$AZURE_DEVOPS_REPO" --output json 2>pipelines_err.log); then
    err_msg=$(cat pipelines_err.log)
    rm -f pipelines_err.log
    
    echo "ERROR: Could not list pipelines."
    failures_json=$(echo "$failures_json" | jq \
        --arg title "Cannot Access Pipelines for Failure Analysis" \
        --arg details "Failed to access pipelines for repository $AZURE_DEVOPS_REPO: $err_msg" \
        --arg severity "3" \
        --arg next_steps "Verify repository name and permissions to access pipeline information" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
    echo "$failures_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f pipelines_err.log

pipeline_count=$(echo "$pipelines" | jq '. | length')
echo "Found $pipeline_count pipeline(s) for repository"

if [ "$pipeline_count" -eq 0 ]; then
    failures_json=$(echo "$failures_json" | jq \
        --arg title "No Pipelines Found for Repository" \
        --arg details "No CI/CD pipelines found for repository $AZURE_DEVOPS_REPO - application issues may not be related to pipeline failures" \
        --arg severity "1" \
        --arg next_steps "Check if the application has alternative deployment methods or if pipelines are configured in different repositories" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
    echo "$failures_json" > "$OUTPUT_FILE"
    exit 0
fi

# Analyze each pipeline for recent failures
total_failures=0
total_runs=0
failed_pipelines=()
deployment_failures=0
test_failures=0
build_failures=0

for ((i=0; i<pipeline_count; i++)); do
    pipeline_json=$(echo "$pipelines" | jq -c ".[$i]")
    pipeline_id=$(echo "$pipeline_json" | jq -r '.id')
    pipeline_name=$(echo "$pipeline_json" | jq -r '.name')
    
    echo "Analyzing pipeline: $pipeline_name (ID: $pipeline_id)"
    
    # Get recent runs for this pipeline
    if recent_runs=$(az pipelines runs list --pipeline-id "$pipeline_id" --query "[?finishTime >= '$from_date']" --output json 2>/dev/null); then
        run_count=$(echo "$recent_runs" | jq '. | length')
        failed_runs=$(echo "$recent_runs" | jq '[.[] | select(.result == "failed")] | length')
        
        total_runs=$((total_runs + run_count))
        total_failures=$((total_failures + failed_runs))
        
        echo "  Recent runs: $run_count, Failed: $failed_runs"
        
        if [ "$failed_runs" -gt 0 ]; then
            failed_pipelines+=("$pipeline_name:$failed_runs")
            
            # Analyze failure patterns
            for ((j=0; j<$(echo "$recent_runs" | jq '. | length'); j++)); do
                run_json=$(echo "$recent_runs" | jq -c ".[$j]")
                run_result=$(echo "$run_json" | jq -r '.result')
                
                if [ "$run_result" = "failed" ]; then
                    run_id=$(echo "$run_json" | jq -r '.id')
                    run_reason=$(echo "$run_json" | jq -r '.reason // "manual"')
                    run_start=$(echo "$run_json" | jq -r '.startTime')
                    run_finish=$(echo "$run_json" | jq -r '.finishTime')
                    
                    # Categorize failure types based on pipeline name patterns
                    if [[ "$pipeline_name" =~ [Dd]eploy|[Rr]elease|[Pp]rod ]]; then
                        deployment_failures=$((deployment_failures + 1))
                    elif [[ "$pipeline_name" =~ [Tt]est|[Qq]uality ]]; then
                        test_failures=$((test_failures + 1))
                    else
                        build_failures=$((build_failures + 1))
                    fi
                    
                    # Get failure details if available
                    failure_details="Pipeline run failed"
                    if run_details=$(az pipelines runs show --id "$run_id" --output json 2>/dev/null); then
                        # Extract basic failure information
                        run_url=$(echo "$run_details" | jq -r '._links.web.href // ""')
                        failure_details="Pipeline run failed. View details: $run_url"
                    fi
                    
                    # Create specific failure entries for high-impact failures
                    if [[ "$pipeline_name" =~ [Dd]eploy|[Rr]elease|[Pp]rod ]] || [ "$failed_runs" -gt 2 ]; then
                        failures_json=$(echo "$failures_json" | jq \
                            --arg title "Critical Pipeline Failure: $pipeline_name" \
                            --arg details "Pipeline '$pipeline_name' failed on $run_start (Run ID: $run_id). This may be directly related to application issues." \
                            --arg severity "3" \
                            --arg next_steps "Review pipeline logs for specific failure reasons. Check if deployment or critical build processes are broken. Pipeline URL: ${run_url:-'N/A'}" \
                            '. += [{
                               "title": $title,
                               "details": $details,
                               "severity": ($severity | tonumber),
                               "next_steps": $next_steps
                             }]')
                    fi
                fi
            done
        fi
        
        # Check for consistently failing pipelines
        if [ "$run_count" -gt 0 ] && [ "$failed_runs" -gt 0 ]; then
            failure_rate=$(echo "scale=0; $failed_runs * 100 / $run_count" | bc -l 2>/dev/null || echo "0")
            
            if [ "$failure_rate" -gt 50 ]; then
                failures_json=$(echo "$failures_json" | jq \
                    --arg title "High Pipeline Failure Rate: $pipeline_name" \
                    --arg details "Pipeline '$pipeline_name' has ${failure_rate}% failure rate ($failed_runs/$run_count) in the last $ANALYSIS_DAYS days" \
                    --arg severity "3" \
                    --arg next_steps "Pipeline '$pipeline_name' is consistently failing. This indicates systemic issues that may be causing application problems. Review pipeline configuration and recent changes." \
                    '. += [{
                       "title": $title,
                       "details": $details,
                       "severity": ($severity | tonumber),
                       "next_steps": $next_steps
                     }]')
            fi
        fi
    else
        echo "  Warning: Could not get recent runs for pipeline $pipeline_name"
    fi
done

# Analyze overall pipeline health
if [ "$total_runs" -gt 0 ]; then
    overall_failure_rate=$(echo "scale=1; $total_failures * 100 / $total_runs" | bc -l 2>/dev/null || echo "0")
    echo "Overall pipeline statistics:"
    echo "  Total runs: $total_runs"
    echo "  Total failures: $total_failures"
    echo "  Failure rate: ${overall_failure_rate}%"
    
    # High overall failure rate
    if (( $(echo "$overall_failure_rate > 25" | bc -l 2>/dev/null || echo "0") )); then
        failures_json=$(echo "$failures_json" | jq \
            --arg title "High Overall Pipeline Failure Rate" \
            --arg details "Overall pipeline failure rate is ${overall_failure_rate}% ($total_failures/$total_runs) - indicates systemic CI/CD issues" \
            --arg severity "3" \
            --arg next_steps "High failure rate suggests systemic issues with CI/CD processes. Review common failure patterns, infrastructure issues, and consider pipeline stability improvements." \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
    
    # Deployment failures are critical
    if [ "$deployment_failures" -gt 0 ]; then
        failures_json=$(echo "$failures_json" | jq \
            --arg title "Deployment Pipeline Failures Detected" \
            --arg details "$deployment_failures deployment pipeline failures in the last $ANALYSIS_DAYS days - directly impacts application availability" \
            --arg severity "4" \
            --arg next_steps "Deployment failures are critical and likely directly related to application issues. Review deployment logs, configuration, and infrastructure status immediately." \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
    
    # Test failures might indicate quality issues
    if [ "$test_failures" -gt 0 ]; then
        failures_json=$(echo "$failures_json" | jq \
            --arg title "Test Pipeline Failures Detected" \
            --arg details "$test_failures test pipeline failures in the last $ANALYSIS_DAYS days - may indicate code quality issues" \
            --arg severity "2" \
            --arg next_steps "Test failures may indicate code quality issues that could cause application problems. Review test results and fix failing tests." \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
    
    # Build failures prevent deployments
    if [ "$build_failures" -gt 0 ]; then
        failures_json=$(echo "$failures_json" | jq \
            --arg title "Build Pipeline Failures Detected" \
            --arg details "$build_failures build pipeline failures in the last $ANALYSIS_DAYS days - prevents new deployments and fixes" \
            --arg severity "3" \
            --arg next_steps "Build failures prevent deployment of fixes. Review build logs for compilation errors, dependency issues, or configuration problems." \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
else
    failures_json=$(echo "$failures_json" | jq \
        --arg title "No Recent Pipeline Activity" \
        --arg details "No pipeline runs found in the last $ANALYSIS_DAYS days - application issues are not related to recent CI/CD activity" \
        --arg severity "1" \
        --arg next_steps "Application issues are not related to recent pipeline activity. Check manual deployments, external dependencies, or infrastructure changes." \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Check for recent successful deployments (might help identify when issues started)
echo "Checking for recent successful deployments..."
last_successful_deployment=""
for ((i=0; i<pipeline_count; i++)); do
    pipeline_json=$(echo "$pipelines" | jq -c ".[$i]")
    pipeline_id=$(echo "$pipeline_json" | jq -r '.id')
    pipeline_name=$(echo "$pipeline_json" | jq -r '.name')
    
    # Focus on deployment pipelines
    if [[ "$pipeline_name" =~ [Dd]eploy|[Rr]elease|[Pp]rod ]]; then
        if successful_runs=$(az pipelines runs list --pipeline-id "$pipeline_id" --result succeeded --top 1 --output json 2>/dev/null); then
            if [ "$(echo "$successful_runs" | jq '. | length')" -gt 0 ]; then
                last_success_time=$(echo "$successful_runs" | jq -r '.[0].finishTime')
                last_successful_deployment="$pipeline_name at $last_success_time"
                break
            fi
        fi
    fi
done

if [ -n "$last_successful_deployment" ]; then
    failures_json=$(echo "$failures_json" | jq \
        --arg title "Last Successful Deployment Reference" \
        --arg details "Last successful deployment: $last_successful_deployment - use this as a reference point for troubleshooting" \
        --arg severity "1" \
        --arg next_steps "Compare current application state with the last successful deployment. Check what changed between then and now." \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# If no issues found, provide a summary
if [ "$(echo "$failures_json" | jq '. | length')" -eq 0 ]; then
    failures_json=$(echo "$failures_json" | jq \
        --arg title "No Recent Pipeline Failures" \
        --arg details "No significant pipeline failures detected in the last $ANALYSIS_DAYS days. Application issues are likely not related to CI/CD pipeline problems." \
        --arg severity "1" \
        --arg next_steps "Since pipelines are healthy, focus troubleshooting on runtime issues, external dependencies, infrastructure, or manual configuration changes." \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Write final JSON
echo "$failures_json" > "$OUTPUT_FILE"
echo "Pipeline failure analysis completed. Results saved to $OUTPUT_FILE"

# Output summary
echo ""
echo "=== PIPELINE FAILURE ANALYSIS SUMMARY ==="
echo "Analysis Period: Last $ANALYSIS_DAYS days"
echo "Total Pipeline Runs: $total_runs"
echo "Total Failures: $total_failures" 
if [ "$total_runs" -gt 0 ]; then
    echo "Overall Failure Rate: $(echo "scale=1; $total_failures * 100 / $total_runs" | bc -l 2>/dev/null || echo "0")%"
fi
echo "Deployment Failures: $deployment_failures"
echo "Test Failures: $test_failures"
echo "Build Failures: $build_failures"
echo ""
echo "$failures_json" | jq -r '.[] | "Issue: \(.title)\nDetails: \(.details)\nSeverity: \(.severity)\nNext Steps: \(.next_steps)\n---"' 