#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AZURE_DEVOPS_PROJECT
#   AZURE_DEVOPS_REPO
#
# This script:
#   1) Checks for potential security incidents
#   2) Analyzes suspicious activity patterns
#   3) Identifies security policy violations
#   4) Provides incident response guidance
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"
: "${AZURE_DEVOPS_REPO:?Must set AZURE_DEVOPS_REPO}"

echo "Security Incident Analysis for Repository..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Project: $AZURE_DEVOPS_PROJECT"
echo "Repository: $AZURE_DEVOPS_REPO"
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Ensure Azure CLI is logged in and DevOps extension is installed
if ! az extension show --name azure-devops &>/dev/null; then
    echo "Installing Azure DevOps CLI extension..."
    az extension add --name azure-devops --output none
fi

# Configure Azure DevOps CLI defaults
az devops configure --defaults organization="https://dev.azure.com/$AZURE_DEVOPS_ORG" project="$AZURE_DEVOPS_PROJECT" --output none

echo ""
echo "=== SECURITY INCIDENT ANALYSIS ==="
echo ""

# Check for recent suspicious pull request activity
echo "1. SUSPICIOUS PULL REQUEST ACTIVITY"
echo "===================================="
if recent_prs=$(az repos pr list --repository "$AZURE_DEVOPS_REPO" --status all --top 20 --output json 2>/dev/null); then
    pr_count=$(echo "$recent_prs" | jq '. | length')
    echo "Analyzing $pr_count recent pull requests for suspicious patterns..."
    
    # Check for PRs with suspicious characteristics
    suspicious_prs=0
    
    for ((i=0; i<pr_count; i++)); do
        pr_json=$(echo "$recent_prs" | jq -c ".[$i]")
        pr_id=$(echo "$pr_json" | jq -r '.pullRequestId')
        pr_title=$(echo "$pr_json" | jq -r '.title')
        created_by=$(echo "$pr_json" | jq -r '.createdBy.displayName // "unknown"')
        created_date=$(echo "$pr_json" | jq -r '.creationDate')
        
        # Check for suspicious patterns in PR titles
        if [[ "$pr_title" =~ (password|secret|key|token|credential|backdoor|hack|exploit) ]]; then
            echo "  ALERT: Suspicious PR #$pr_id: '$pr_title' by $created_by"
            suspicious_prs=$((suspicious_prs + 1))
        fi
        
        # Check for PRs created outside business hours (simplified check)
        hour=$(date -d "$created_date" +%H 2>/dev/null || echo "12")
        if [ "$hour" -lt 6 ] || [ "$hour" -gt 22 ]; then
            echo "  WARNING: Off-hours PR #$pr_id created at $(date -d "$created_date" +"%Y-%m-%d %H:%M" 2>/dev/null || echo "unknown time") by $created_by"
        fi
    done
    
    if [ "$suspicious_prs" -eq 0 ]; then
        echo "  No obviously suspicious pull requests detected"
    else
        echo "  ALERT: $suspicious_prs potentially suspicious pull requests found"
    fi
else
    echo "  Cannot access pull request information"
fi

echo ""

# Check for unusual branch activity
echo "2. UNUSUAL BRANCH ACTIVITY"
echo "=========================="
if branches=$(az repos ref list --repository "$AZURE_DEVOPS_REPO" --filter "heads/" --output json 2>/dev/null); then
    branch_count=$(echo "$branches" | jq '. | length')
    echo "Analyzing $branch_count branches for suspicious patterns..."
    
    suspicious_branches=0
    
    for ((i=0; i<branch_count; i++)); do
        branch_json=$(echo "$branches" | jq -c ".[$i]")
        branch_name=$(echo "$branch_json" | jq -r '.name' | sed 's|refs/heads/||')
        
        # Check for suspicious branch names
        if [[ "$branch_name" =~ (temp|test|hack|exploit|backdoor|malware|virus) ]]; then
            echo "  ALERT: Suspicious branch name: $branch_name"
            suspicious_branches=$((suspicious_branches + 1))
        fi
        
        # Check for branches with random/encoded names
        if [[ "$branch_name" =~ ^[a-f0-9]{32,}$ ]] || [[ "$branch_name" =~ ^[A-Za-z0-9+/]{20,}={0,2}$ ]]; then
            echo "  WARNING: Branch with encoded/hash-like name: $branch_name"
            suspicious_branches=$((suspicious_branches + 1))
        fi
    done
    
    if [ "$suspicious_branches" -eq 0 ]; then
        echo "  No suspicious branch names detected"
    else
        echo "  ALERT: $suspicious_branches potentially suspicious branches found"
    fi
else
    echo "  Cannot access branch information"
fi

echo ""

# Check for security policy violations
echo "3. SECURITY POLICY VIOLATIONS"
echo "============================="
if repo_info=$(az repos show --repository "$AZURE_DEVOPS_REPO" --output json 2>/dev/null); then
    repo_id=$(echo "$repo_info" | jq -r '.id')
    
    # Check branch protection status
    if branch_policies=$(az repos policy list --repository-id "$repo_id" --output json 2>/dev/null); then
        enabled_policies=$(echo "$branch_policies" | jq '[.[] | select(.isEnabled == true)] | length')
        
        if [ "$enabled_policies" -eq 0 ]; then
            echo "  CRITICAL: No branch protection policies enabled - repository is vulnerable"
            echo "    - Direct pushes to main branch allowed"
            echo "    - No code review requirements"
            echo "    - No build validation"
        else
            echo "  Branch protection policies: $enabled_policies enabled"
            
            # Check for weak policies
            reviewer_policies=$(echo "$branch_policies" | jq '[.[] | select(.type.displayName == "Minimum number of reviewers" and .isEnabled == true)]')
            
            if [ "$(echo "$reviewer_policies" | jq '. | length')" -eq 0 ]; then
                echo "  WARNING: No required reviewers policy - code can be merged without review"
            else
                # Check reviewer policy strength
                min_reviewers=$(echo "$reviewer_policies" | jq -r '.[0].settings.minimumApproverCount // 1')
                creator_vote_counts=$(echo "$reviewer_policies" | jq -r '.[0].settings.creatorVoteCounts // true')
                
                if [ "$min_reviewers" -lt 2 ]; then
                    echo "  WARNING: Only $min_reviewers reviewer required - consider requiring at least 2"
                fi
                
                if [ "$creator_vote_counts" = "true" ]; then
                    echo "  WARNING: Authors can approve their own changes - reduces security"
                fi
            fi
        fi
    else
        echo "  Cannot access branch policy information"
    fi
else
    echo "  Cannot access repository information"
fi

echo ""

# Check for recent permission changes
echo "4. PERMISSION CHANGES ANALYSIS"
echo "=============================="
# This is a simplified check - in practice, you'd need audit logs
echo "Checking for potential permission issues..."

if permissions=$(az devops security permission list --id "$repo_id" --output json 2>/dev/null); then
    permission_count=$(echo "$permissions" | jq '. | length')
    echo "  Repository has $permission_count permission entries"
    
    if [ "$permission_count" -gt 50 ]; then
        echo "  WARNING: Large number of permissions may indicate over-permissioning"
        echo "    - Review and audit all repository permissions"
        echo "    - Remove unnecessary access grants"
        echo "    - Follow principle of least privilege"
    fi
else
    echo "  Cannot access permission information"
fi

echo ""

# Check for build/pipeline security issues
echo "5. BUILD PIPELINE SECURITY"
echo "=========================="
if builds=$(az pipelines list --repository "$AZURE_DEVOPS_REPO" --output json 2>/dev/null); then
    build_count=$(echo "$builds" | jq '. | length')
    echo "Analyzing $build_count build pipelines for security issues..."
    
    if [ "$build_count" -eq 0 ]; then
        echo "  WARNING: No build pipelines - cannot validate code security automatically"
    else
        for ((i=0; i<build_count && i<3; i++)); do
            build_json=$(echo "$builds" | jq -c ".[$i]")
            build_name=$(echo "$build_json" | jq -r '.name')
            build_id=$(echo "$build_json" | jq -r '.id')
            
            echo "  Checking build: $build_name"
            
            # Check recent build failures that might indicate security issues
            if recent_runs=$(az pipelines runs list --pipeline-id "$build_id" --top 5 --output json 2>/dev/null); then
                failed_runs=$(echo "$recent_runs" | jq '[.[] | select(.result == "failed")] | length')
                
                if [ "$failed_runs" -gt 3 ]; then
                    echo "    WARNING: $failed_runs recent failures - may indicate security scanning failures"
                fi
            fi
        done
    fi
else
    echo "  Cannot access build pipeline information"
fi

echo ""

# Repository content security indicators
echo "6. REPOSITORY CONTENT SECURITY"
echo "=============================="
echo "Checking for potential security issues in repository structure..."

# Check repository size for potential data exfiltration
if repo_info=$(az repos show --repository "$AZURE_DEVOPS_REPO" --output json 2>/dev/null); then
    repo_size=$(echo "$repo_info" | jq -r '.size // 0')
    repo_size_mb=$(echo "scale=2; $repo_size / 1048576" | bc -l 2>/dev/null || echo "0")
    
    echo "  Repository size: ${repo_size_mb}MB"
    
    if (( $(echo "$repo_size > 1073741824" | bc -l) )); then  # 1GB
        echo "  ALERT: Very large repository (${repo_size_mb}MB) - investigate for:"
        echo "    - Accidentally committed large files"
        echo "    - Data dumps or backups"
        echo "    - Binary files that should use Git LFS"
    fi
fi

# Check for suspicious repository naming
if [[ "$AZURE_DEVOPS_REPO" =~ (backup|dump|export|secret|private|internal|confidential) ]]; then
    echo "  WARNING: Repository name '$AZURE_DEVOPS_REPO' may indicate sensitive content"
    echo "    - Verify repository contents are appropriate"
    echo "    - Ensure proper access controls"
fi

echo ""

# Incident response recommendations
echo "7. INCIDENT RESPONSE RECOMMENDATIONS"
echo "===================================="
echo "If security incidents are suspected:"
echo ""
echo "Immediate Actions:"
echo "  1. Enable branch protection immediately if not already enabled"
echo "  2. Review all recent commits and pull requests"
echo "  3. Audit repository permissions and remove unnecessary access"
echo "  4. Check for any exposed secrets or credentials"
echo "  5. Review build pipeline configurations for security"
echo ""
echo "Investigation Steps:"
echo "  1. Clone repository and scan for secrets/credentials"
echo "  2. Review commit history for suspicious changes"
echo "  3. Check Azure DevOps audit logs for access patterns"
echo "  4. Verify all contributors are authorized team members"
echo "  5. Scan for malware or suspicious code patterns"
echo ""
echo "Remediation:"
echo "  1. Rotate any exposed credentials immediately"
echo "  2. Remove malicious code if found"
echo "  3. Strengthen branch protection policies"
echo "  4. Implement security scanning in CI/CD pipeline"
echo "  5. Provide security training to development team"
echo ""
echo "Monitoring:"
echo "  1. Set up alerts for unusual repository activity"
echo "  2. Regular security scans of repository contents"
echo "  3. Monitor for policy violations"
echo "  4. Review access logs regularly"

echo ""
echo "=== SECURITY ANALYSIS COMPLETE ==="
echo "Review findings above and take immediate action on any CRITICAL or ALERT items."
echo "Document all findings and actions taken for security audit trail." 