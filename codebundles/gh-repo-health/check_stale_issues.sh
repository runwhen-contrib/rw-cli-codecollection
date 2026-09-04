#!/bin/bash

set -e
source "$(dirname "$0")/_github_auth.sh"

STALE_ISSUE_DAYS=${STALE_ISSUE_DAYS:-60}
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
current_time=$(date +%s)

echo "Checking stale issue accumulation across repositories (stale threshold: ${STALE_ISSUE_DAYS} days)..." >&2

repositories=$(get_repositories_to_analyze)

all_open_issues=0
all_stale_issues=0
all_unassigned_issues=0
all_unlabeled_issues=0
all_unresponded_issues=0
repos_analyzed=0
repos_with_high_backlog="[]"
unresponded_issues_list="[]"

while IFS= read -r repo_name; do
    if [ -n "$repo_name" ]; then
        repos_analyzed=$((repos_analyzed + 1))
        echo "Checking issues for repository: $repo_name" >&2

        open_issues_json=$(perform_curl "https://api.github.com/repos/$repo_name/issues?state=open&per_page=100&sort=created&direction=asc" || echo "[]")
        if ! echo "$open_issues_json" | jq -e 'type == "array"' >/dev/null 2>>/dev/null 2>&1 ]; then1; then
            sleep 0.2
            continue
        fi

        open_count=$(echo "$open_issues_json" | jq 'length')
        all_open_issues=$((all_open_issues + open_count))
        if [ "$open_count" -eq 0 ]; then
            sleep 0.2
            continue
        fi

        stale_count=0
        unassigned_count=0
        unlabeled_count=0
        unresponded_count=0

        while IFS= read -r issue; do
            if [ -z "$issue" ] || [ "$issue" = "null" ]; then continue; fi
            has_pr=$(echo "$issue" | jq -r '.pull_request // empty')
            if [ -n "$has_pr" ]; then continue; fi

            updated_at=$(echo "$issue" | jq -r '.updated_at // ""')
            assignee=$(echo "$issue" | jq -r '.assignee.login // ""')
            labels=$(echo "$issue" | jq -r '.labels | length // 0')
            issue_number=$(echo "$issue" | jq -r '.number')
            issue_title=$(echo "$issue" | jq -r '.title')
            issue_author=$(echo "$issue" | jq -r '.user.login // "unknown"')

            if [ -n "$updated_at" ] && [ "$updated_at" != "null" ]; then
                updated_timestamp=$(date -d "$updated_at" +%s 2>/dev/null || echo "0")
                if [ "$updated_timestamp" != "0" ]; then
                    days_since_update=$(( (current_time - updated_timestamp) / 86400 ))
                    if [ "$days_since_update" -gt "$STALE_ISSUE_DAYS" ]; then
                        stale_count=$((stale_count + 1))
                    fi
                fi
            fi

            if [ -z "$assignee" ] || [ "$assignee" = "null" ]; then
                unassigned_count=$((unassigned_count + 1))
            fi
            if [ "$labels" -eq 0 ]; then
                unlabeled_count=$((unlabeled_count + 1))
            fi

            if [ "$days_since_update" -gt "$STALE_ISSUE_DAYS" ] || [ "$unassigned_count" -gt 0 ]; then
                comments_json=$(perform_curl "https://api.github.com/repos/$repo_name/issues/$issue_number/comments?per_page=3&sort=created&direction=desc" || echo "[]")
                last_comment_author=$(echo "$comments_json" | jq -r '.[0].user.login // "unknown"')

                if [ "$last_comment_author" = "$issue_author" ] || [ -z "$last_comment_author" ] || [ "$last_comment_author" = "null" ]; then
                    if [ "$days_since_update" -gt "$STALE_ISSUE_DAYS" ]; then
                        unresponded_count=$((unresponded_count + 1))
                        unresponded_obj=$(jq -n \
                            --arg repo "$repo_name" \
                            --argjson number "$issue_number" \
                            --arg title "$issue_title" \
                            --arg author "$issue_author" \
                            --arg last_comment_by "$last_comment_author" \
                            --arg updated_at "$updated_at" \
                            --arg assignee "$assignee" \
                            --argjson days_since_update "$days_since_update" \
                            '{
                                repository: $repo,
                                issue_number: $number,
                                title: $title,
                                author: $author,
                                last_comment_by: $last_comment_by,
                                updated_at: $updated_at,
                                assigned_to: (if $assignee == "" then null else $assignee end),
                                days_since_last_team_response: $days_since_update
                            }')
                        unresponded_issues_list=$(echo "$unresponded_issues_list" | jq --argjson obj "$unresponded_obj" '. + [$obj]')
                    fi
                fi
            fi

        done <<< $(echo "$open_issues_json" | jq -c '.[]')

        all_stale_issues=$((all_stale_issues + stale_count))
        all_unassigned_issues=$((all_unassigned_issues + unassigned_count))
        all_unlabeled_issues=$((all_unlabeled_issues + unlabeled_count))
        all_unresponded_issues=$((all_unresponded_issues + unresponded_count))

        if [ "$stale_count" -gt 5 ] || [ "$unassigned_count" -gt 10 ]; then
            backlog_obj=$(jq -n \
                --arg repo "$repo_name" \
                --argjson open "$open_count" \
                --argjson stale "$stale_count" \
                --argjson unassigned "$unassigned_count" \
                --argjson unlabeled "$unlabeled_count" \
                '{
                    repository: $repo,
                    open_issues: $open,
                    stale_issues: $stale,
                    unassigned_issues: $unassigned,
                    unlabeled_issues: $unlabeled
                }')
            repos_with_high_backlog=$(echo "$repos_with_high_backlog" | jq --argjson obj "$backlog_obj" '. + [$obj]')
        fi

        sleep 0.3
    fi
done <<< "$repositories"

cat << EOF
{
    "repositories_analyzed": $repos_analyzed,
    "total_open_issues": $all_open_issues,
    "stale_issues": $all_stale_issues,
    "unassigned_issues": $all_unassigned_issues,
    "unlabeled_issues": $all_unlabeled_issues,
    "unresponded_issues": $all_unresponded_issues,
    "stale_threshold_days": $STALE_ISSUE_DAYS,
    "repos_with_high_backlog": $repos_with_high_backlog,
    "unresponded_issues_detail": $unresponded_issues_list,
    "report_time": "$NOW_ISO"
}
EOF