#!/bin/bash

set -e
source "$(dirname "$0")/_github_auth.sh"

DORMANT_DAYS=${DORMANT_DAYS:-90}
current_time=$(date +%s)

echo "Checking for dormant repositories (no activity in ${DORMANT_DAYS}+ days)..." >&2

repositories=$(get_repositories_to_analyze)

all_dormant="[]"
total_repos=0

while IFS= read -r repo_name; do
    if [ -n "$repo_name" ]; then
        total_repos=$((total_repos + 1))
        echo "Checking repository: $repo_name" >&2

        repo_json=$(perform_curl "https://api.github.com/repos/$repo_name" || echo "{}")
        pushed_at=$(echo "$repo_json" | jq -r '.pushed_at // ""')
        created_at=$(echo "$repo_json" | jq -r '.created_at // ""')
        updated_at=$(echo "$repo_json" | jq -r '.updated_at // ""')
        archived=$(echo "$repo_json" | jq -r '.archived // false')
        default_branch=$(echo "$repo_json" | jq -r '.default_branch // "main"')
        html_url=$(echo "$repo_json" | jq -r '.html_url // ""')

        repo_age_days=0
        if [ -n "$created_at" ] && [ "$created_at" != "null" ]; then
            created_timestamp=$(date -d "$created_at" +%s 2>/dev/null || echo "0")
            if [ "$created_timestamp" != "0" ]; then
                repo_age_days=$(( (current_time - created_timestamp) / 86400 ))
            fi
        fi

        last_activity_date="$pushed_at"
        [ -z "$last_activity_date" ] || [ "$last_activity_date" = "null" ] && last_activity_date="$updated_at"

        activity_days=0
        if [ -n "$last_activity_date" ] && [ "$last_activity_date" != "null" ]; then
            activity_timestamp=$(date -d "$last_activity_date" +%s 2>/dev/null || echo "0")
            if [ "$activity_timestamp" != "0" ]; then
                activity_days=$(( (current_time - activity_timestamp) / 86400 ))
            fi
        else
            activity_days="$repo_age_days"
        fi

        last_committer="N/A"
        last_commit_date="$last_activity_date"
        last_commit_msg="N/A"

        commits_json=$(perform_curl "https://api.github.com/repos/$repo_name/commits?per_page=1" 2>/dev/null || echo "[]")
        if [ "$(echo "$commits_json" | jq 'type // "object"')" = '"array"' ]; then
            commit_count=$(echo "$commits_json" | jq 'length')
            if [ "$commit_count" -gt 0 ]; then
                last_committer=$(echo "$commits_json" | jq -r '.[0].commit.author.name // "N/A"')
                last_commit_date=$(echo "$commits_json" | jq -r '.[0].commit.author.date // "'"$last_activity_date"'"')
                last_commit_msg=$(echo "$commits_json" | jq -r '.[0].commit.message // "N/A"' | head -1)
            fi
        fi

        if [ "$activity_days" -gt "$DORMANT_DAYS" ] || [ "$archived" = "true" ]; then
            dormant_obj=$(jq -n \
                --arg repo "$repo_name" \
                --argjson days "$activity_days" \
                --argjson archived "$archived" \
                --arg default_branch "$default_branch" \
                --arg html_url "$html_url" \
                --arg last_committer "$last_committer" \
                --arg last_commit_date "$last_commit_date" \
                --arg last_commit_msg "$last_commit_msg" \
                --argjson repo_age_days "$repo_age_days" \
                '{
                    repository: $repo,
                    days_since_last_activity: $days,
                    archived: $archived,
                    default_branch: $default_branch,
                    html_url: $html_url,
                    last_committer: $last_committer,
                    last_commit_date: $last_commit_date,
                    last_commit_message: $last_commit_msg,
                    repo_age_days: $repo_age_days
                }')
            all_dormant=$(echo "$all_dormant" | jq --argjson obj "$dormant_obj" '. + [$obj]')
            echo "DORMANT: $repo_name — $activity_days days since last activity by $last_committer" >&2
        fi

        sleep 0.2
    fi
done <<< "$repositories"

dormant_count=$(echo "$all_dormant" | jq 'length')

cat << EOF
{
    "repositories_analyzed": $total_repos,
    "dormant_repositories_count": $dormant_count,
    "dormant_threshold_days": $DORMANT_DAYS,
    "dormant_repositories": $all_dormant
}
EOF