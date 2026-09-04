#!/bin/bash

set -e
source "$(dirname "$0")/_github_auth.sh"

function perform_curl {
    local url="$1"
    local response
    response=$(curl -sS "${HEADERS[@]}" "$url") || error_exit "Failed to perform curl request to $url"
    echo "$response"
}

STALE_BRANCH_DAYS=${STALE_BRANCH_DAYS:-60}
MAX_STALE_BRANCHES_PER_REPO=${MAX_STALE_BRANCHES_PER_REPO:-10}
current_time=$(date +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "Auditing branch hygiene across repositories (stale threshold: ${STALE_BRANCH_DAYS} days)..." >&2

repositories=$(get_repositories_to_analyze)

all_stale_branches="[]"
total_branches=0
total_stale=0
repos_analyzed=0

while IFS= read -r repo_name; do
    if [ -n "$repo_name" ]; then
        repos_analyzed=$((repos_analyzed + 1))
        echo "Checking branches for repository: $repo_name" >&2

        repo_json=$(perform_curl "https://api.github.com/repos/$repo_name" || echo '{"default_branch":"main"}')
        default_branch=$(echo "$repo_json" | jq -r '.default_branch // "main"')

        branches_json=$(perform_curl "https://api.github.com/repos/$repo_name/branches?per_page=100" || echo "[]")

        if ! echo "$branches_json" | jq -e 'type == "array"' >/dev/null 2>>/dev/null 2>&1 ]; then1; then
            sleep 0.2
            continue
        fi

        branch_count=$(echo "$branches_json" | jq 'length')
        total_branches=$((total_branches + branch_count))

        stale_branches_for_repo="[]"
        stale_count=0

        while IFS= read -r branch; do
            if [ -z "$branch" ] || [ "$branch" = "null" ]; then continue; fi

            branch_name=$(echo "$branch" | jq -r '.name')
            protected_branch=$(echo "$branch" | jq -r '.protected // false')

            if [ "$branch_name" = "$default_branch" ] || [ "$protected_branch" = "true" ]; then
                continue
            fi

            commit_sha=$(echo "$branch" | jq -r '.commit.sha // ""')
            if [ -z "$commit_sha" ] || [ "$commit_sha" = "null" ]; then continue; fi

            commit_json=$(perform_curl "https://api.github.com/repos/$repo_name/commits/$commit_sha" 2>/dev/null || echo '{"commit":{"author":{"date":null}}}')
            commit_date=$(echo "$commit_json" | jq -r '.commit.author.date // ""')
            committer=$(echo "$commit_json" | jq -r '.commit.author.name // "unknown"')

            if [ -z "$commit_date" ] || [ "$commit_date" = "null" ]; then continue; fi

            commit_timestamp=$(date -d "$commit_date" +%s 2>/dev/null || echo "0")
            if [ "$commit_timestamp" = "0" ]; then continue; fi

            days_since_commit=$(( (current_time - commit_timestamp) / 86400 ))

            if [ "$days_since_commit" -gt "$STALE_BRANCH_DAYS" ]; then
                stale_count=$((stale_count + 1))
                branch_obj=$(jq -n \
                    --arg repo "$repo_name" \
                    --arg branch "$branch_name" \
                    --arg last_commit_date "$commit_date" \
                    --argjson days_since_commit "$days_since_commit" \
                    --argjson protected "$protected_branch" \
                    --arg committer "$committer" \
                    '{
                        repository: $repo,
                        branch: $branch,
                        last_commit_date: $last_commit_date,
                        days_since_commit: $days_since_commit,
                        protected: $protected,
                        last_committer: $committer
                    }')
                stale_branches_for_repo=$(echo "$stale_branches_for_repo" | jq --argjson obj "$branch_obj" '. + [$obj]')

            if [ "$stale_count" -ge "$MAX_STALE_BRANCHES_PER_REPO" ]; then break; fi
            fi

        done <<< $(echo "$branches_json" | jq -c '.[]')

        total_stale=$((total_stale + stale_count))
        all_stale_branches=$(echo "$all_stale_branches" | jq --argjson branches "$stale_branches_for_repo" '. + $branches')

        if [ "$branch_count" -gt 0 ]; then
            echo "Repository $repo_name: $branch_count total branches, $stale_count stale" >&2
        fi

        sleep 0.3
    fi
done <<< "$repositories"

cat << EOF
{
    "repositories_analyzed": $repos_analyzed,
    "total_branches_analyzed": $total_branches,
    "stale_branches_count": $total_stale,
    "stale_threshold_days": $STALE_BRANCH_DAYS,
    "stale_branches": $all_stale_branches,
    "report_time": "$NOW_ISO"
}
EOF