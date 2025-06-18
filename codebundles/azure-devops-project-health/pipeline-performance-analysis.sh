#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AZURE_DEVOPS_PROJECT
#
# This script:
#   1) Analyzes pipeline performance trends
#   2) Identifies performance bottlenecks
#   3) Compares current vs historical performance
#   4) Provides optimization recommendations
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"

OUTPUT_FILE="pipeline_performance_analysis.json"
analysis_json='[]'

echo "Pipeline Performance Analysis..."
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
echo "Getting pipelines in project..."
if ! pipelines=$(az pipelines list --output json 2>pipelines_err.log); then
    err_msg=$(cat pipelines_err.log)
    rm -f pipelines_err.log
    
    echo "ERROR: Could not list pipelines."
    analysis_json=$(echo "$analysis_json" | jq \
        --arg title "Failed to List Pipelines" \
        --arg details "$err_msg" \
        --arg severity "3" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber)
        }]')
    echo "$analysis_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f pipelines_err.log

echo "$pipelines" > pipelines.json
pipeline_count=$(jq '. | length' pipelines.json)

if [ "$pipeline_count" -eq 0 ]; then
    echo "No pipelines found in project."
    analysis_json='[{"title": "No Pipelines Found", "details": "No pipelines found in the project", "severity": 2}]'
    echo "$analysis_json" > "$OUTPUT_FILE"
    exit 0
fi

echo "Found $pipeline_count pipelines. Analyzing performance..."

# Analyze each pipeline
for ((i=0; i<pipeline_count; i++)); do
    pipeline_json=$(jq -c ".[${i}]" pipelines.json)
    
    pipeline_id=$(echo "$pipeline_json" | jq -r '.id')
    pipeline_name=$(echo "$pipeline_json" | jq -r '.name')
    
    echo "Analyzing pipeline: $pipeline_name (ID: $pipeline_id)"
    
    # Get recent successful runs (last 30 days)
    from_date=$(date -d "30 days ago" -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "  Getting recent successful runs..."
    
    if recent_runs=$(az pipelines runs list --pipeline-id "$pipeline_id" --query "[?result=='succeeded' && finishTime >= '$from_date']" --output json 2>runs_err.log); then
        run_count=$(echo "$recent_runs" | jq '. | length')
        
        if [ "$run_count" -gt 0 ]; then
            echo "    Found $run_count successful runs for analysis"
            
            # Calculate performance metrics
            echo "    Calculating performance metrics..."
            
            # Extract durations (in seconds)
            durations=$(echo "$recent_runs" | jq -r '.[] | select(.startTime != null and .finishTime != null) | ((.finishTime | fromdateiso8601) - (.startTime | fromdateiso8601))')
            
            if [ -n "$durations" ] && [ "$(echo "$durations" | wc -l)" -gt 0 ]; then
                # Calculate statistics
                avg_duration=$(echo "$durations" | awk '{sum+=$1} END {print sum/NR}' | xargs printf "%.0f")
                min_duration=$(echo "$durations" | sort -n | head -1 | xargs printf "%.0f")
                max_duration=$(echo "$durations" | sort -n | tail -1 | xargs printf "%.0f")
                
                # Calculate median
                sorted_durations=$(echo "$durations" | sort -n)
                median_duration=$(echo "$sorted_durations" | awk '{a[NR]=$1} END {print (NR%2==1) ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2}' | xargs printf "%.0f")
                
                # Convert to human readable format
                avg_duration_min=$((avg_duration / 60))
                min_duration_min=$((min_duration / 60))
                max_duration_min=$((max_duration / 60))
                median_duration_min=$((median_duration / 60))
                
                echo "      Average: ${avg_duration_min}m, Min: ${min_duration_min}m, Max: ${max_duration_min}m, Median: ${median_duration_min}m"
                
                # Check for performance issues
                performance_issues=()
                severity=1
                
                # Check for high variability (max > 3x min)
                if [ "$max_duration" -gt $((min_duration * 3)) ] && [ "$min_duration" -gt 60 ]; then
                    performance_issues+=("High duration variability: ${min_duration_min}m to ${max_duration_min}m")
                    severity=2
                fi
                
                # Check for long average duration (>30 minutes)
                if [ "$avg_duration" -gt 1800 ]; then
                    performance_issues+=("Long average duration: ${avg_duration_min} minutes")
                    severity=2
                fi
                
                # Check for very long maximum duration (>2 hours)
                if [ "$max_duration" -gt 7200 ]; then
                    performance_issues+=("Very long maximum duration: ${max_duration_min} minutes")
                    severity=3
                fi
                
                # Get queue time analysis
                echo "    Analyzing queue times..."
                queue_times=$(echo "$recent_runs" | jq -r '.[] | select(.queueTime != null and .startTime != null) | ((.startTime | fromdateiso8601) - (.queueTime | fromdateiso8601))')
                
                if [ -n "$queue_times" ] && [ "$(echo "$queue_times" | wc -l)" -gt 0 ]; then
                    avg_queue_time=$(echo "$queue_times" | awk '{sum+=$1} END {print sum/NR}' | xargs printf "%.0f")
                    max_queue_time=$(echo "$queue_times" | sort -n | tail -1 | xargs printf "%.0f")
                    
                    avg_queue_time_min=$((avg_queue_time / 60))
                    max_queue_time_min=$((max_queue_time / 60))
                    
                    echo "      Average queue time: ${avg_queue_time_min}m, Max: ${max_queue_time_min}m"
                    
                    # Check for long queue times
                    if [ "$avg_queue_time" -gt 300 ]; then  # 5 minutes
                        performance_issues+=("Long average queue time: ${avg_queue_time_min} minutes")
                        severity=2
                    fi
                    
                    if [ "$max_queue_time" -gt 1800 ]; then  # 30 minutes
                        performance_issues+=("Very long maximum queue time: ${max_queue_time_min} minutes")
                        severity=3
                    fi
                else
                    avg_queue_time=0
                    max_queue_time=0
                    avg_queue_time_min=0
                    max_queue_time_min=0
                fi
                
                # Analyze success rate
                echo "    Analyzing success rate..."
                all_runs=$(az pipelines runs list --pipeline-id "$pipeline_id" --query "[?finishTime >= '$from_date']" --output json 2>/dev/null || echo '[]')
                total_runs=$(echo "$all_runs" | jq '. | length')
                
                if [ "$total_runs" -gt 0 ]; then
                    success_rate=$(echo "scale=1; $run_count * 100 / $total_runs" | bc -l 2>/dev/null || echo "0")
                    echo "      Success rate: ${success_rate}% ($run_count/$total_runs)"
                    
                    # Check for low success rate
                    if (( $(echo "$success_rate < 80" | bc -l) )); then
                        performance_issues+=("Low success rate: ${success_rate}%")
                        severity=3
                    fi
                else
                    success_rate="0"
                fi
                
                # Build performance summary
                if [ ${#performance_issues[@]} -eq 0 ]; then
                    issues_summary="Performance appears normal"
                    title="Pipeline Performance: $pipeline_name - Normal"
                else
                    issues_summary=$(IFS='; '; echo "${performance_issues[*]}")
                    title="Pipeline Performance: $pipeline_name - Issues Found"
                fi
                
            else
                echo "      No valid duration data found"
                avg_duration=0
                min_duration=0
                max_duration=0
                median_duration=0
                avg_queue_time=0
                max_queue_time=0
                success_rate="0"
                issues_summary="No performance data available"
                title="Pipeline Performance: $pipeline_name - No Data"
                severity=2
            fi
        else
            echo "    No successful runs found in the last 30 days"
            avg_duration=0
            min_duration=0
            max_duration=0
            median_duration=0
            avg_queue_time=0
            max_queue_time=0
            success_rate="0"
            issues_summary="No successful runs in last 30 days"
            title="Pipeline Performance: $pipeline_name - No Recent Success"
            severity=3
        fi
    else
        echo "    Warning: Could not get pipeline runs"
        run_count=0
        avg_duration=0
        min_duration=0
        max_duration=0
        median_duration=0
        avg_queue_time=0
        max_queue_time=0
        success_rate="0"
        issues_summary="Could not retrieve performance data"
        title="Pipeline Performance: $pipeline_name - Data Unavailable"
        severity=2
    fi
    rm -f runs_err.log
    
    # Add to analysis results
    analysis_json=$(echo "$analysis_json" | jq \
        --arg title "$title" \
        --arg pipeline_name "$pipeline_name" \
        --arg pipeline_id "$pipeline_id" \
        --arg run_count "$run_count" \
        --arg avg_duration "$avg_duration" \
        --arg min_duration "$min_duration" \
        --arg max_duration "$max_duration" \
        --arg median_duration "$median_duration" \
        --arg avg_queue_time "$avg_queue_time" \
        --arg max_queue_time "$max_queue_time" \
        --arg success_rate "$success_rate" \
        --arg issues_summary "$issues_summary" \
        --arg severity "$severity" \
        '. += [{
           "title": $title,
           "pipeline_name": $pipeline_name,
           "pipeline_id": $pipeline_id,
           "successful_runs": ($run_count | tonumber),
           "avg_duration_seconds": ($avg_duration | tonumber),
           "min_duration_seconds": ($min_duration | tonumber),
           "max_duration_seconds": ($max_duration | tonumber),
           "median_duration_seconds": ($median_duration | tonumber),
           "avg_queue_time_seconds": ($avg_queue_time | tonumber),
           "max_queue_time_seconds": ($max_queue_time | tonumber),
           "success_rate_percent": $success_rate,
           "issues_summary": $issues_summary,
           "severity": ($severity | tonumber),
           "details": "Pipeline \($pipeline_name): \($run_count) successful runs, avg duration \(($avg_duration | tonumber) / 60)m, success rate \($success_rate)%. Issues: \($issues_summary)"
         }]')
done

# Clean up temporary files
rm -f pipelines.json

# Write final JSON
echo "$analysis_json" > "$OUTPUT_FILE"
echo "Pipeline performance analysis completed. Results saved to $OUTPUT_FILE"

# Output summary to stdout
echo ""
echo "=== PIPELINE PERFORMANCE SUMMARY ==="
echo "$analysis_json" | jq -r '.[] | "Pipeline: \(.pipeline_name)\nRuns: \(.successful_runs), Avg Duration: \((.avg_duration_seconds / 60) | floor)m\nSuccess Rate: \(.success_rate_percent)%\nIssues: \(.issues_summary)\n---"' 