#!/bin/bash

set -e
source "$(dirname "$0")/_github_auth.sh"

OVERDUE_COMMIT_THRESHOLD=${OVERDUE_COMMIT_THRESHOLD:-30}
LOOKBACK_MONTHS=${RELEASE_LOOKBACK_MONTHS:-6}
current_time=$(date +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "Checking release health and cadence across repositories..." >&2

repositories=$(get_repositories_to_analyze)

all_releases="[]"
repos_analyzed=0
repos_without_releases=0
repos_overdue=0

while IFS= read -r repo_name; do
    if [ -n "$repo_name" ]; then
        repos_analyzed=$((repos_analyzed + 1))
        echo "Checking releases for repository: $repo_name" >&2

        releases_json=$(perform_curl "https://api.github.com/repos/$repo_name/releases?per_page=10" || echo "[]")
        repo_json=$(perform_curl "https://api.github.com/repos/$repo_name" 2>/dev/null || echo '{"default_branch":"main"}')
        default_branch=$(echo "$repo_json" | jq -r '.default_branch // "main"')

        uses_github_releases=false
        last_release_tag=""
        last_release_date=""
        releases_count=0
        days_since_release=0

        if echo "$releases_json" | jq -e 'type == "array"' >/dev/null 2>&1 && [ "$(echo "$releases_json" | jq 'length')" -gt 0 ]; then
            uses_github_releases=true
            releases_count=$(echo "$releases_json" | jq 'length')
            last_release_tag=$(echo "$releases_json" | jq -r '.[0].tag_name')
            last_release_date=$(echo "$releases_json" | jq -r '.[0].published_at')
            if [ -n "$last_release_date" ] && [ "$last_release_date" != "null" ]; then
                release_timestamp=$(date -d "$last_release_date" +%s 2>/dev/null || echo "0")
                if [ "$release_timestamp" != "0" ]; then
                    days_since_release=$(( (current_time - release_timestamp) / 86400 ))
                fi
            fi
        fi

        releases_last_n_months=0
        cutoff_date=$(date -d "$LOOKBACK_MONTHS months ago" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
        if [ -n "$cutoff_date" ] && [ "$uses_github_releases" = "true" ]; then
            releases_last_n_months=$(echo "$releases_json" | jq --arg cutoff "$cutoff_date" '[.[] | select(.published_at > $cutoff)] | length')
        fi

        commits_since_release=0
        release_overdue=false
        if [ -n "$last_release_tag" ] && [ "$last_release_tag" != "null" ] && [ "$days_since_release" -gt 0 ]; then
            compare_resp=$(perform_curl "https://api.github.com/repos/$repo_name/compare/$last_release_tag...$default_branch" 2>/dev/null || echo '{"ahead_by":0}')
            commits_since_release=$(echo "$compare_resp" | jq -r '.ahead_by // 0')
            if [ "$commits_since_release" -gt "$OVERDUE_COMMIT_THRESHOLD" ] && [ "$days_since_release" -gt 14 ]; then
                release_overdue=true
            fi
        fi

        avg_days_between=0
        if [ "$releases_last_n_months" -gt 0 ]; then
            avg_days_between=$(( (LOOKBACK_MONTHS * 30) / releases_last_n_months ))
        fi

        if [ -z "$last_release_tag" ] || [ "$last_release_tag" = "null" ]; then
            repos_without_releases=$((repos_without_releases + 1))
        fi
        if [ "$release_overdue" = "true" ]; then
            repos_overdue=$((repos_overdue + 1))
        fi

        release_obj=$(jq -n \
            --arg repo "$repo_name" \
            --arg last_release "$last_release_tag" \
            --arg last_release_date "$last_release_date" \
            --argjson days_since_release "$days_since_release" \
            --argjson commits_since_release "$commits_since_release" \
            --argjson releases_last_n_months "$releases_last_n_months" \
            --argjson avg_days_between "$avg_days_between" \
            --argjson release_overdue "$release_overdue" \
            --argjson uses_github_releases "$uses_github_releases" \
            '{
                repository: $repo,
                last_release: (if $last_release == "" or $last_release == "null" then null else $last_release end),
                last_release_date: (if $last_release_date == "" or $last_release_date == "null" then null else $last_release_date end),
                days_since_release: $days_since_release,
                commits_since_release: $commits_since_release,
                releases_last_6_months: $releases_last_n_months,
                avg_days_between_releases: $avg_days_between,
                release_overdue: $release_overdue,
                uses_github_releases: $uses_github_releases
            }')
        all_releases=$(echo "$all_releases" | jq --argjson obj "$release_obj" '. + [$obj]')

        echo "Repository $repo_name: releases=${releases_count}, last=${last_release_tag}, days_since=${days_since_release}, overdue=${release_overdue}" >&2
        sleep 0.3
    fi
done <<< "$repositories"

cat << EOF
{
    "repositories_analyzed": $repos_analyzed,
    "repos_without_releases": $repos_without_releases,
    "repos_with_overdue_releases": $repos_overdue,
    "overdue_commit_threshold": $OVERDUE_COMMIT_THRESHOLD,
    "lookback_months": $LOOKBACK_MONTHS,
    "release_details": $all_releases,
    "report_time": "$NOW_ISO"
}
EOF