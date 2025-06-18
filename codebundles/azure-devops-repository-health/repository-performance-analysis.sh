#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AZURE_DEVOPS_PROJECT
#   AZURE_DEVOPS_REPO
#   REPO_SIZE_THRESHOLD_MB (optional, default: 500)
#
# This script:
#   1) Analyzes repository performance characteristics
#   2) Identifies large files and storage issues
#   3) Checks for Git LFS usage patterns
#   4) Detects performance optimization opportunities
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"
: "${AZURE_DEVOPS_REPO:?Must set AZURE_DEVOPS_REPO}"
: "${REPO_SIZE_THRESHOLD_MB:=500}"

OUTPUT_FILE="repository_performance_analysis.json"
performance_json='[]'

echo "Analyzing Repository Performance..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Project: $AZURE_DEVOPS_PROJECT"
echo "Repository: $AZURE_DEVOPS_REPO"
echo "Size Threshold: ${REPO_SIZE_THRESHOLD_MB}MB"

# Ensure Azure CLI is logged in and DevOps extension is installed
if ! az extension show --name azure-devops &>/dev/null; then
    echo "Installing Azure DevOps CLI extension..."
    az extension add --name azure-devops --output none
fi

# Configure Azure DevOps CLI defaults
az devops configure --defaults organization="https://dev.azure.com/$AZURE_DEVOPS_ORG" project="$AZURE_DEVOPS_PROJECT" --output none

# Get repository information
echo "Getting repository information..."
if ! repo_info=$(az repos show --repository "$AZURE_DEVOPS_REPO" --output json 2>repo_err.log); then
    err_msg=$(cat repo_err.log)
    rm -f repo_err.log
    
    echo "ERROR: Could not get repository information."
    performance_json=$(echo "$performance_json" | jq \
        --arg title "Cannot Access Repository for Performance Analysis" \
        --arg details "Failed to access repository $AZURE_DEVOPS_REPO: $err_msg" \
        --arg severity "3" \
        --arg next_steps "Verify repository name and permissions to access repository information" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
    echo "$performance_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f repo_err.log

repo_id=$(echo "$repo_info" | jq -r '.id')
repo_size=$(echo "$repo_info" | jq -r '.size // 0')
repo_url=$(echo "$repo_info" | jq -r '.remoteUrl')

echo "Repository ID: $repo_id"
echo "Repository Size: $repo_size bytes"

# Convert size to MB for analysis
repo_size_mb=$(echo "scale=2; $repo_size / 1048576" | bc -l 2>/dev/null || echo "0")
threshold_bytes=$(echo "$REPO_SIZE_THRESHOLD_MB * 1048576" | bc -l 2>/dev/null || echo "524288000")

echo "Repository Size: ${repo_size_mb}MB"
echo "Threshold: ${REPO_SIZE_THRESHOLD_MB}MB"

# Check repository size against threshold
if (( $(echo "$repo_size > $threshold_bytes" | bc -l) )); then
    performance_json=$(echo "$performance_json" | jq \
        --arg title "Repository Size Exceeds Threshold" \
        --arg details "Repository size (${repo_size_mb}MB) exceeds threshold (${REPO_SIZE_THRESHOLD_MB}MB) - may impact clone and fetch performance" \
        --arg severity "2" \
        --arg next_steps "Review repository contents for large files, implement Git LFS for binaries, and consider repository cleanup" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Check for very large repositories (>1GB)
if (( $(echo "$repo_size > 1073741824" | bc -l) )); then
    performance_json=$(echo "$performance_json" | jq \
        --arg title "Very Large Repository" \
        --arg details "Repository size (${repo_size_mb}MB) is very large (>1GB) - will significantly impact performance" \
        --arg severity "3" \
        --arg next_steps "Urgent: Review repository for large files, implement Git LFS, consider repository splitting, and clean up history if needed" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Analyze repository statistics if available
echo "Getting repository statistics..."
if repo_stats=$(az repos stats show --repository "$AZURE_DEVOPS_REPO" --output json 2>/dev/null); then
    commits_count=$(echo "$repo_stats" | jq -r '.commitsCount // 0')
    pushes_count=$(echo "$repo_stats" | jq -r '.pushesCount // 0')
    
    echo "Repository statistics:"
    echo "  Commits: $commits_count"
    echo "  Pushes: $pushes_count"
    
    # Check for excessive commit history
    if [ "$commits_count" -gt 10000 ]; then
        performance_json=$(echo "$performance_json" | jq \
            --arg title "Excessive Commit History" \
            --arg details "Repository has $commits_count commits - large history may impact performance" \
            --arg severity "1" \
            --arg next_steps "Consider repository history cleanup or shallow clones for CI/CD to improve performance" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
    
    # Check push frequency patterns
    if [ "$commits_count" -gt 0 ] && [ "$pushes_count" -gt 0 ]; then
        commits_per_push=$(echo "scale=1; $commits_count / $pushes_count" | bc -l 2>/dev/null || echo "1")
        
        if (( $(echo "$commits_per_push < 1.5" | bc -l) )); then
            performance_json=$(echo "$performance_json" | jq \
                --arg title "Frequent Small Pushes" \
                --arg details "Average of $commits_per_push commits per push - many small pushes may indicate workflow inefficiency" \
                --arg severity "1" \
                --arg next_steps "Consider batching commits or using feature branches to reduce push frequency" \
                '. += [{
                   "title": $title,
                   "details": $details,
                   "severity": ($severity | tonumber),
                   "next_steps": $next_steps
                 }]')
        fi
    fi
else
    echo "Repository statistics not available"
fi

# Check for Git LFS usage indicators
echo "Checking for Git LFS configuration..."
# This is a simplified check - in practice, you'd clone the repo and check .gitattributes
# For now, we'll check repository characteristics that suggest LFS should be used

if (( $(echo "$repo_size > 104857600" | bc -l) )); then  # 100MB
    # Large repository without obvious LFS usage might indicate missing LFS
    performance_json=$(echo "$performance_json" | jq \
        --arg title "Large Repository May Need Git LFS" \
        --arg details "Repository size (${repo_size_mb}MB) suggests it may contain large files that should use Git LFS" \
        --arg severity "2" \
        --arg next_steps "Review repository for large binary files and implement Git LFS for files >50MB" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Check repository URL for performance indicators
echo "Analyzing repository URL structure..."
if [[ "$repo_url" =~ \.git$ ]]; then
    echo "Repository URL follows standard Git convention"
else
    performance_json=$(echo "$performance_json" | jq \
        --arg title "Non-Standard Repository URL" \
        --arg details "Repository URL doesn't follow standard Git conventions - may impact tooling compatibility" \
        --arg severity "1" \
        --arg next_steps "Verify repository URL configuration and ensure compatibility with Git tools" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Check for branch count impact on performance
echo "Checking branch count impact..."
if branches=$(az repos ref list --repository "$AZURE_DEVOPS_REPO" --filter "heads/" --output json 2>/dev/null); then
    branch_count=$(echo "$branches" | jq '. | length')
    
    echo "Branch count: $branch_count"
    
    if [ "$branch_count" -gt 100 ]; then
        performance_json=$(echo "$performance_json" | jq \
            --arg title "Excessive Branch Count Impacts Performance" \
            --arg details "Repository has $branch_count branches - may impact fetch and clone performance" \
            --arg severity "2" \
            --arg next_steps "Clean up stale branches and implement branch lifecycle management to improve performance" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
else
    echo "Cannot access branch information"
fi

# Check for potential performance issues based on repository name patterns
echo "Checking for repository naming patterns that suggest performance issues..."
if [[ "$AZURE_DEVOPS_REPO" =~ (backup|archive|dump|export|migration) ]]; then
    performance_json=$(echo "$performance_json" | jq \
        --arg title "Repository Name Suggests Archive/Backup Usage" \
        --arg details "Repository name '$AZURE_DEVOPS_REPO' suggests it may be used for archival - consider alternative storage for large archives" \
        --arg severity "1" \
        --arg next_steps "Consider using Azure Blob Storage or other archival solutions for large backup data instead of Git repositories" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Check for build performance impact
echo "Checking build performance indicators..."
if builds=$(az pipelines list --repository "$AZURE_DEVOPS_REPO" --output json 2>/dev/null); then
    build_count=$(echo "$builds" | jq '. | length')
    
    if [ "$build_count" -gt 0 ]; then
        # Check recent build performance
        first_build_id=$(echo "$builds" | jq -r '.[0].id')
        
        if recent_runs=$(az pipelines runs list --pipeline-id "$first_build_id" --top 5 --output json 2>/dev/null); then
            slow_builds=0
            total_builds=$(echo "$recent_runs" | jq '. | length')
            
            for ((i=0; i<total_builds; i++)); do
                run_json=$(echo "$recent_runs" | jq -c ".[$i]")
                start_time=$(echo "$run_json" | jq -r '.startTime // empty')
                finish_time=$(echo "$run_json" | jq -r '.finishTime // empty')
                
                if [ -n "$start_time" ] && [ -n "$finish_time" ]; then
                    start_ts=$(date -d "$start_time" +%s 2>/dev/null || echo "0")
                    finish_ts=$(date -d "$finish_time" +%s 2>/dev/null || echo "0")
                    duration_minutes=$(( (finish_ts - start_ts) / 60 ))
                    
                    if [ "$duration_minutes" -gt 30 ]; then
                        slow_builds=$((slow_builds + 1))
                    fi
                fi
            done
            
            if [ "$slow_builds" -gt 0 ] && [ "$total_builds" -gt 0 ]; then
                slow_build_rate=$(echo "scale=1; $slow_builds * 100 / $total_builds" | bc -l 2>/dev/null || echo "0")
                
                if (( $(echo "$slow_build_rate >= 60" | bc -l) )); then
                    performance_json=$(echo "$performance_json" | jq \
                        --arg title "Slow Build Performance" \
                        --arg details "$slow_builds out of $total_builds recent builds took >30 minutes - may be related to repository size or structure" \
                        --arg severity "2" \
                        --arg next_steps "Optimize build process, consider shallow clones, implement build caching, and review repository structure" \
                        '. += [{
                           "title": $title,
                           "details": $details,
                           "severity": ($severity | tonumber),
                           "next_steps": $next_steps
                         }]')
                fi
            fi
        fi
    fi
fi

# If no performance issues found, add a healthy status
if [ "$(echo "$performance_json" | jq '. | length')" -eq 0 ]; then
    performance_json=$(echo "$performance_json" | jq \
        --arg title "Repository Performance: Optimal" \
        --arg details "Repository size (${repo_size_mb}MB) and structure appear optimized for good performance" \
        --arg severity "1" \
        --arg next_steps "Continue monitoring repository size and consider implementing Git LFS if large files are added" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Write final JSON
echo "$performance_json" > "$OUTPUT_FILE"
echo "Repository performance analysis completed. Results saved to $OUTPUT_FILE"

# Output summary to stdout
echo ""
echo "=== REPOSITORY PERFORMANCE SUMMARY ==="
echo "Repository: $AZURE_DEVOPS_REPO"
echo "Size: ${repo_size_mb}MB"
echo "Threshold: ${REPO_SIZE_THRESHOLD_MB}MB"
echo ""
echo "$performance_json" | jq -r '.[] | "Issue: \(.title)\nDetails: \(.details)\nSeverity: \(.severity)\n---"' 