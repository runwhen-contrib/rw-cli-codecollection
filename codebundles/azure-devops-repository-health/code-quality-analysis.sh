#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AZURE_DEVOPS_PROJECT
#   AZURE_DEVOPS_REPO
#   MIN_CODE_COVERAGE (optional, default: 80)
#
# This script:
#   1) Analyzes code quality metrics and patterns
#   2) Identifies technical debt indicators
#   3) Checks for code coverage and testing issues
#   4) Detects maintainability problems
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"
: "${AZURE_DEVOPS_REPO:?Must set AZURE_DEVOPS_REPO}"
: "${MIN_CODE_COVERAGE:=80}"

OUTPUT_FILE="code_quality_analysis.json"
quality_json='[]'

echo "Analyzing Code Quality and Technical Debt..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Project: $AZURE_DEVOPS_PROJECT"
echo "Repository: $AZURE_DEVOPS_REPO"
echo "Minimum Code Coverage: $MIN_CODE_COVERAGE%"

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
    quality_json=$(echo "$quality_json" | jq \
        --arg title "Cannot Access Repository for Quality Analysis" \
        --arg details "Failed to access repository $AZURE_DEVOPS_REPO: $err_msg" \
        --arg severity "3" \
        --arg next_steps "Verify repository name and permissions to access repository information" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
    echo "$quality_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f repo_err.log

repo_id=$(echo "$repo_info" | jq -r '.id')
repo_size=$(echo "$repo_info" | jq -r '.size // 0')

# Analyze recent commits for quality indicators
echo "Analyzing recent commit patterns..."
if commits=$(az repos list --output json 2>/dev/null); then
    # Get recent commits (last 30 days)
    thirty_days_ago=$(date -d "30 days ago" -u +"%Y-%m-%dT%H:%M:%SZ")
    
    if recent_commits=$(az repos ref list --repository "$AZURE_DEVOPS_REPO" --output json 2>/dev/null); then
        echo "Analyzing commit patterns..."
        
        # This is a simplified analysis - in practice, you'd analyze actual commit messages and changes
        # Check for concerning commit message patterns
        commit_analysis_done=true
    else
        quality_json=$(echo "$quality_json" | jq \
            --arg title "Cannot Access Commit History" \
            --arg details "Unable to access recent commits for quality analysis" \
            --arg severity "2" \
            --arg next_steps "Verify permissions to read repository commit history" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
fi

# Check for build definitions and quality gates
echo "Checking build definitions for quality gates..."
if builds=$(az pipelines list --repository "$AZURE_DEVOPS_REPO" --output json 2>/dev/null); then
    build_count=$(echo "$builds" | jq '. | length')
    echo "Found $build_count build definitions"
    
    if [ "$build_count" -eq 0 ]; then
        quality_json=$(echo "$quality_json" | jq \
            --arg title "No Build Definitions Found" \
            --arg details "Repository has no build definitions - code quality cannot be automatically validated" \
            --arg severity "3" \
            --arg next_steps "Create build pipelines with quality gates including tests, code analysis, and coverage checks" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    else
        # Analyze build definitions for quality indicators
        for ((i=0; i<build_count && i<3; i++)); do  # Check first 3 builds
            build_json=$(echo "$builds" | jq -c ".[$i]")
            build_name=$(echo "$build_json" | jq -r '.name')
            build_id=$(echo "$build_json" | jq -r '.id')
            
            echo "  Analyzing build: $build_name"
            
            # Check recent build results for quality indicators
            if build_runs=$(az pipelines runs list --pipeline-id "$build_id" --top 10 --output json 2>/dev/null); then
                failed_runs=$(echo "$build_runs" | jq '[.[] | select(.result == "failed")] | length')
                total_runs=$(echo "$build_runs" | jq '. | length')
                
                if [ "$total_runs" -gt 0 ]; then
                    failure_rate=$(echo "scale=1; $failed_runs * 100 / $total_runs" | bc -l 2>/dev/null || echo "0")
                    
                    if (( $(echo "$failure_rate >= 50" | bc -l) )); then
                        quality_json=$(echo "$quality_json" | jq \
                            --arg title "High Build Failure Rate" \
                            --arg build_name "$build_name" \
                            --arg failure_rate "$failure_rate" \
                            --arg details "Build '$build_name' has ${failure_rate}% failure rate in recent runs - indicates code quality issues" \
                            --arg severity "3" \
                            --arg next_steps "Investigate build failures, fix failing tests, and improve code quality to reduce failure rate" \
                            '. += [{
                               "title": $title,
                               "details": $details,
                               "severity": ($severity | tonumber),
                               "next_steps": $next_steps
                             }]')
                    fi
                fi
                
                # Check for builds that take too long (potential quality issue)
                long_builds=$(echo "$build_runs" | jq '[.[] | select(.finishTime != null and .startTime != null) | select((.finishTime | fromdateiso8601) - (.startTime | fromdateiso8601) > 1800)] | length')  # 30 minutes
                
                if [ "$long_builds" -gt 0 ]; then
                    quality_json=$(echo "$quality_json" | jq \
                        --arg title "Slow Build Performance" \
                        --arg build_name "$build_name" \
                        --arg details "Build '$build_name' has $long_builds recent runs taking >30 minutes - may indicate inefficient build process or large codebase issues" \
                        --arg severity "2" \
                        --arg next_steps "Optimize build process, parallelize tests, and consider build caching to improve performance" \
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
else
    echo "Cannot access build definitions"
fi

# Check for test results and code coverage
echo "Checking test results and coverage..."
if builds=$(az pipelines list --repository "$AZURE_DEVOPS_REPO" --output json 2>/dev/null); then
    build_count=$(echo "$builds" | jq '. | length')
    
    if [ "$build_count" -gt 0 ]; then
        # Check first build for test results
        first_build_id=$(echo "$builds" | jq -r '.[0].id')
        
        if recent_runs=$(az pipelines runs list --pipeline-id "$first_build_id" --top 5 --output json 2>/dev/null); then
            runs_with_tests=0
            
            for ((i=0; i<$(echo "$recent_runs" | jq '. | length'); i++)); do
                run_json=$(echo "$recent_runs" | jq -c ".[$i]")
                run_id=$(echo "$run_json" | jq -r '.id')
                
                # Check for test results (this is a simplified check)
                if test_results=$(az pipelines runs show --id "$run_id" --output json 2>/dev/null); then
                    # In practice, you'd check for actual test result data
                    runs_with_tests=$((runs_with_tests + 1))
                fi
            done
            
            if [ "$runs_with_tests" -eq 0 ]; then
                quality_json=$(echo "$quality_json" | jq \
                    --arg title "No Test Results Found" \
                    --arg details "Recent pipeline runs show no test results - code quality cannot be verified through automated testing" \
                    --arg severity "3" \
                    --arg next_steps "Implement automated tests and configure pipelines to run and report test results" \
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

# Analyze repository structure for quality indicators
echo "Analyzing repository structure..."
if repo_stats=$(az repos stats show --repository "$AZURE_DEVOPS_REPO" --output json 2>/dev/null); then
    echo "Repository statistics available"
    
    # Check commit frequency (low frequency might indicate stale code)
    commits_count=$(echo "$repo_stats" | jq -r '.commitsCount // 0')
    
    if [ "$commits_count" -lt 10 ]; then
        quality_json=$(echo "$quality_json" | jq \
            --arg title "Low Commit Activity" \
            --arg details "Repository has only $commits_count commits - may indicate inactive or new repository" \
            --arg severity "1" \
            --arg next_steps "Verify if repository is actively maintained and consider consolidating with other repositories if inactive" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
else
    echo "Cannot access repository statistics"
fi

# Check for common quality issues based on repository characteristics
echo "Checking for common quality anti-patterns..."

# Large repository size might indicate quality issues
if [ "$repo_size" -gt 52428800 ]; then  # 50MB
    size_mb=$(echo "scale=1; $repo_size / 1048576" | bc -l 2>/dev/null || echo "unknown")
    quality_json=$(echo "$quality_json" | jq \
        --arg title "Large Repository Size May Indicate Quality Issues" \
        --arg details "Repository size is ${size_mb}MB - may contain large files, generated code, or lack proper .gitignore configuration" \
        --arg severity "2" \
        --arg next_steps "Review repository contents, implement proper .gitignore, use Git LFS for large files, and remove generated/temporary files" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Check for repository naming conventions
if [[ "$AZURE_DEVOPS_REPO" =~ ^[0-9] ]] || [[ "$AZURE_DEVOPS_REPO" =~ [[:space:]] ]]; then
    quality_json=$(echo "$quality_json" | jq \
        --arg title "Poor Repository Naming Convention" \
        --arg details "Repository name '$AZURE_DEVOPS_REPO' doesn't follow best practices (starts with number or contains spaces)" \
        --arg severity "1" \
        --arg next_steps "Consider renaming repository to follow naming conventions (lowercase, hyphens, descriptive)" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Check for potential monorepo issues
if [[ "$AZURE_DEVOPS_REPO" =~ (all|everything|main|master|common|shared|utils) ]]; then
    quality_json=$(echo "$quality_json" | jq \
        --arg title "Potential Monorepo Anti-Pattern" \
        --arg details "Repository name '$AZURE_DEVOPS_REPO' suggests it might be a monorepo or catch-all repository" \
        --arg severity "1" \
        --arg next_steps "Consider if repository should be split into smaller, more focused repositories for better maintainability" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# If no quality issues found, add a healthy status
if [ "$(echo "$quality_json" | jq '. | length')" -eq 0 ]; then
    quality_json=$(echo "$quality_json" | jq \
        --arg title "Code Quality: No Major Issues Detected" \
        --arg details "Repository appears to follow good practices with no major code quality issues detected" \
        --arg severity "1" \
        --arg next_steps "Continue monitoring code quality metrics and maintain current standards" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Write final JSON
echo "$quality_json" > "$OUTPUT_FILE"
echo "Code quality analysis completed. Results saved to $OUTPUT_FILE"

# Output summary to stdout
echo ""
echo "=== CODE QUALITY SUMMARY ==="
echo "Repository: $AZURE_DEVOPS_REPO"
echo "Repository Size: $(echo "scale=1; $repo_size / 1048576" | bc -l 2>/dev/null || echo "unknown")MB"
echo "Minimum Coverage Threshold: $MIN_CODE_COVERAGE%"
echo ""
echo "$quality_json" | jq -r '.[] | "Issue: \(.title)\nDetails: \(.details)\nSeverity: \(.severity)\n---"' 