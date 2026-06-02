#!/usr/bin/env bash
set -euo pipefail
# NOTE: `set -x` is intentionally NOT used (it leaks AZURE_DEVOPS_PAT into logs
# and bloats output). Set AZ_DEBUG=1 to opt in to tracing for local debugging.
[ "${AZ_DEBUG:-0}" = "1" ] && set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AZURE_DEVOPS_PROJECT
#
# OPTIONAL ENV VARS:
#   RW_LOOKBACK_WINDOW   - window for recent commit activity (default 24h; the
#                          deep runbook typically sets 30d)
#   MAX_REPOS            - cap on repos whose commit history is fetched (deep
#                          per-item work; default 50)
#
# This script (Phase 0 single-pass refactor):
#   1) Lists repositories ONCE.
#   2) Fetches active pull requests and branch policies PROJECT-WIDE in ONE call
#      each (instead of one PR-list + one policy-list call per repository) and
#      derives per-repo counts with jq.
#   3) Fetches recent commit activity per repo (the one signal with no bulk API),
#      windowed by RW_LOOKBACK_WINDOW and CAPPED to MAX_REPOS repositories.
#   4) Outputs results in JSON format.
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"
: "${RW_LOOKBACK_WINDOW:=24h}"
: "${MAX_REPOS:=50}"
: "${AUTH_TYPE:=service_principal}"
AZURE_DEVOPS_PAT="${AZURE_DEVOPS_PAT:-$azure_devops_pat}"
export AZURE_DEVOPS_EXT_PAT="${AZURE_DEVOPS_PAT}"

source "$(dirname "$0")/_az_helpers.sh"

OUTPUT_FILE="repository_health_analysis.json"
analysis_json='[]'

echo "Repository Health Analysis..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Project:      $AZURE_DEVOPS_PROJECT"

az devops configure --defaults project="$AZURE_DEVOPS_PROJECT" --output none
setup_azure_auth

# Get list of repositories (single call)
echo "Getting repositories in project..."
if ! az_with_retry az repos list --output json; then
    echo "ERROR: Could not list repositories."
    analysis_json=$(echo "$analysis_json" | jq \
        --arg title "Failed to List Repositories" \
        --arg details "Azure DevOps API was unreachable or returned an error after $AZ_RETRY_COUNT retry attempts." \
        --arg severity "3" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber)
        }]')
    echo "$analysis_json" > "$OUTPUT_FILE"
    exit 1
fi
repos="$AZ_RESULT"

echo "$repos" > repos.json
repo_count=$(jq '. | length' repos.json)

if [ "$repo_count" -eq 0 ]; then
    echo "No repositories found in project."
    analysis_json='[{"title": "No Repositories Found", "details": "No repositories found in the project", "severity": 2}]'
    echo "$analysis_json" > "$OUTPUT_FILE"
    rm -f repos.json
    exit 0
fi

echo "Found $repo_count repositories. Fetching project-wide PRs and policies (single pass)..."

# Single-pass: all active PRs for the project in ONE call (was 1 call per repo).
if az_with_retry az repos pr list --status active --output json; then
    echo "$AZ_RESULT" > prs_all.json
    echo "  Fetched $(jq 'length' prs_all.json) active pull requests project-wide."
else
    echo "  WARNING: Could not list project-wide pull requests; PR counts will be 0."
    echo '[]' > prs_all.json
fi

# Single-pass: all branch policy configurations for the project in ONE call.
if az_with_retry az repos policy list --output json; then
    echo "$AZ_RESULT" > policies_all.json
    echo "  Fetched $(jq 'length' policies_all.json) policy configurations project-wide."
else
    echo "  WARNING: Could not list project-wide branch policies; policy counts will be 0."
    echo '[]' > policies_all.json
fi

from_date=$(window_to_min_time "$RW_LOOKBACK_WINDOW")
old_pr_date=$(date -d '14 days ago' -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Commit activity window: since ${from_date} (RW_LOOKBACK_WINDOW=${RW_LOOKBACK_WINDOW}). Commit fetch capped to ${MAX_REPOS} repos."

# Analyze each repository
for ((i=0; i<repo_count; i++)); do
    repo_json=$(jq -c ".[${i}]" repos.json)

    repo_id=$(echo "$repo_json" | jq -r '.id')
    repo_name=$(echo "$repo_json" | jq -r '.name')
    default_branch=$(echo "$repo_json" | jq -r '.defaultBranch // "main"' | sed 's|refs/heads/||')
    repo_size=$(echo "$repo_json" | jq -r '.size // 0')

    echo "Analyzing repository: $repo_name"

    # PR counts derived from the project-wide PR set (no per-repo call).
    open_pr_count=$(jq --arg rid "$repo_id" '[ .[] | select(.repository.id == $rid) ] | length' prs_all.json)
    old_prs=$(jq --arg rid "$repo_id" --arg old "$old_pr_date" \
        '[ .[] | select(.repository.id == $rid and .creationDate < $old) ] | length' prs_all.json)

    # Branch policies derived from the project-wide policy set (no per-repo call).
    default_branch_id="refs/heads/$default_branch"
    policy_count=$(jq --arg rid "$repo_id" --arg ref "$default_branch_id" \
        '[ .[] | select(((.settings.scope // []) | length) == 0
            or ((.settings.scope // []) | any(((.repositoryId // null) == null or .repositoryId == $rid)
                and ((.refName // null) == null or .refName == $ref)))) ] | length' policies_all.json)
    enabled_policies=$(jq --arg rid "$repo_id" --arg ref "$default_branch_id" \
        '[ .[] | select((.isEnabled == true) and (((.settings.scope // []) | length) == 0
            or ((.settings.scope // []) | any(((.repositoryId // null) == null or .repositoryId == $rid)
                and ((.refName // null) == null or .refName == $ref))))) ] | length' policies_all.json)

    # Recent commit activity: the only signal with no bulk API. Windowed and
    # capped to MAX_REPOS to keep the task bounded.
    commit_count=0; unique_authors=0; avg_commits_per_day="0"; most_active_author="None"
    if [ "$i" -lt "$MAX_REPOS" ]; then
        echo "  Checking recent commit activity (since $from_date)..."
        if recent_commits=$(az repos commit list --repository "$repo_name" --query "[?author.date >= '$from_date']" --output json 2>commits_err.log); then
            commit_count=$(echo "$recent_commits" | jq '. | length')
            if [ "$commit_count" -gt 0 ]; then
                unique_authors=$(echo "$recent_commits" | jq -r '.[].author.name' | sort -u | wc -l)
                avg_commits_per_day=$(echo "scale=1; $commit_count / 7" | bc -l 2>/dev/null || echo "0")
                most_active_author=$(echo "$recent_commits" | jq -r '.[].author.name' | sort | uniq -c | sort -nr | head -1 | awk '{print $2" "$3" "$4}' | sed 's/^ *//')
                echo "    Recent activity: $commit_count commits by $unique_authors authors"
            else
                echo "    No recent commit activity"
            fi
        else
            echo "    Warning: Could not get recent commits"
            most_active_author="Unknown"
        fi
        rm -f commits_err.log
    else
        most_active_author="Not analyzed (MAX_REPOS cap)"
        echo "  Skipping commit fetch for $repo_name (beyond MAX_REPOS=$MAX_REPOS cap)"
    fi

    # Determine health status and issues
    issues_found=()
    severity=1

    if [ "$i" -lt "$MAX_REPOS" ]; then
        if [ "$commit_count" -eq 0 ]; then
            issues_found+=("No commits in window")
            severity=2
        elif [ "$commit_count" -lt 3 ] && [ "$unique_authors" -eq 1 ]; then
            issues_found+=("Low commit activity (only $commit_count commits by 1 author)")
            severity=2
        fi
    fi

    if [ "$old_prs" -gt 0 ]; then
        issues_found+=("$old_prs pull requests older than 14 days")
        severity=2
    fi

    if [ "$enabled_policies" -eq 0 ]; then
        issues_found+=("No branch protection policies enabled")
        severity=2
    fi

    if [ "$repo_size" -gt 1000000000 ]; then  # 1GB
        repo_size_mb=$((repo_size / 1024 / 1024))
        issues_found+=("Large repository size: ${repo_size_mb}MB")
        severity=2
    fi

    if [ ${#issues_found[@]} -eq 0 ]; then
        issues_summary="Repository appears healthy"
        title="Repository Health: $repo_name - Healthy"
        next_steps_text="No action required - repository activity and policies appear healthy."
    else
        issues_summary=$(IFS='; '; echo "${issues_found[*]}")
        title="Repository Health: $repo_name - Issues Found"
        next_steps_text="Address the following for repository $repo_name: $issues_summary. Review branch policies, ensure active code review participation, and clean up stale pull requests."
    fi

    analysis_json=$(echo "$analysis_json" | jq \
        --arg title "$title" \
        --arg repo_name "$repo_name" \
        --arg repo_id "$repo_id" \
        --arg default_branch "$default_branch" \
        --arg repo_size "$repo_size" \
        --arg commit_count "$commit_count" \
        --arg unique_authors "$unique_authors" \
        --arg avg_commits_per_day "$avg_commits_per_day" \
        --arg most_active_author "$most_active_author" \
        --arg open_pr_count "$open_pr_count" \
        --arg old_prs "$old_prs" \
        --arg policy_count "$policy_count" \
        --arg enabled_policies "$enabled_policies" \
        --arg issues_summary "$issues_summary" \
        --arg severity "$severity" \
        --arg next_steps "$next_steps_text" \
        '. += [{
           "title": $title,
           "repo_name": $repo_name,
           "repo_id": $repo_id,
           "default_branch": $default_branch,
           "repo_size_bytes": ($repo_size | tonumber),
           "recent_commits": ($commit_count | tonumber),
           "unique_authors": ($unique_authors | tonumber),
           "avg_commits_per_day": $avg_commits_per_day,
           "most_active_author": $most_active_author,
           "open_prs": ($open_pr_count | tonumber),
           "stale_prs": ($old_prs | tonumber),
           "total_policies": ($policy_count | tonumber),
           "enabled_policies": ($enabled_policies | tonumber),
           "issues_summary": $issues_summary,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps,
           "details": "Repository \($repo_name): \($commit_count) commits in window by \($unique_authors) authors (most active: \($most_active_author)). \($open_pr_count) open PRs (\($old_prs) stale). \($enabled_policies)/\($policy_count) branch policies enabled. Issues: \($issues_summary)"
         }]')
done

# Clean up temporary files
rm -f repos.json prs_all.json policies_all.json

# Write final JSON
echo "$analysis_json" > "$OUTPUT_FILE"
echo "Repository health analysis completed. Results saved to $OUTPUT_FILE"

# Output summary to stdout
echo ""
echo "=== REPOSITORY HEALTH SUMMARY ==="
echo "$analysis_json" | jq -r '.[] | "Repository: \(.repo_name)\nRecent Commits: \(.recent_commits) by \(.unique_authors) authors\nOpen PRs: \(.open_prs) (\(.stale_prs) stale)\nPolicies: \(.enabled_policies)/\(.total_policies) enabled\nIssues: \(.issues_summary)\n---"'
