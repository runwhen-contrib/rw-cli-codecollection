#!/bin/bash

set -e
source "$(dirname "$0")/_github_auth.sh"

STALE_PR_DAYS=${STALE_PR_DAYS:-14}
current_time=$(date +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "Checking stale and blocked pull requests (stale threshold: ${STALE_PR_DAYS} days)..." >&2

repositories=$(get_repositories_to_analyze)

all_stale_prs="[]"
all_unreviewed_prs="[]"
all_conflict_prs="[]"
total_open_prs=0
total_stale=0
total_unreviewed=0
total_conflicts=0
repos_analyzed=0

while IFS= read -r repo_name; do
    if [ -n "$repo_name" ]; then
        repos_analyzed=$((repos_analyzed + 1))
        echo "Checking PRs for repository: $repo_name" >&2

        prs_json=$(perform_curl "https://api.github.com/repos/$repo_name/pulls?state=open&sort=created&direction=asc&per_page=100" || echo "[]")
        if ! echo "$prs_json" | jq -e 'type == "array"' >/dev/null 2>>/dev/null 2>&1 ]; then1; then
            sleep 0.2
            continue
        fi

        pr_count=$(echo "$prs_json" | jq 'length')
        total_open_prs=$((total_open_prs + pr_count))

        while IFS= read -r pr; do
            if [ -z "$pr" ] || [ "$pr" = "null" ]; then continue; fi

            pr_number=$(echo "$pr" | jq -r '.number')
            pr_title=$(echo "$pr" | jq -r '.title')
            pr_author=$(echo "$pr" | jq -r '.user.login // "unknown"')
            created_at=$(echo "$pr" | jq -r '.created_at // ""')
            draft=$(echo "$pr" | jq -r '.draft // false')
            html_url=$(echo "$pr" | jq -r '.html_url // ""')
            mergeable_state=$(echo "$pr" | jq -r '.mergeable_state // "unknown"')
            requested_reviewers=$(echo "$pr" | jq -r '[.requested_reviewers[]?.login] | join(",") // ""')

            reviews_json=$(perform_curl "https://api.github.com/repos/$repo_name/pulls/$pr_number/reviews?per_page=20" || echo "[]")
            review_count=$(echo "$reviews_json" | jq 'length // 0')
            approved_by=$(echo "$reviews_json" | jq -r '[.[] | select(.state == "APPROVED") | .user.login] | unique | join(",") // ""')
            changes_requested_by=$(echo "$reviews_json" | jq -r '[.[] | select(.state == "CHANGES_REQUESTED") | .user.login] | unique | join(",") // ""')

            created_timestamp=$(date -d "$created_at" +%s 2>/dev/null || echo "0")
            days_open=0
            if [ "$created_timestamp" != "0" ]; then
                days_open=$(( (current_time - created_timestamp) / 86400 ))
            fi

            waiting_on=""
            IFS=',' read -ra REQ_ARRAY <<< "$requested_reviewers"
            for req in "${REQ_ARRAY[@]}"; do
                req_trimmed=$(echo "$req" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                if [ -z "$req_trimmed" ]; then continue; fi
                if ! echo "$approved_by$changes_requested_by" | grep -q "$req_trimmed"; then
                    if [ -n "$waiting_on" ]; then waiting_on="$waiting_on,"; fi
                    waiting_on="$waiting_on$req_trimmed"
                fi
            done

            has_conflicts=false
            if [ "$mergeable_state" = "dirty" ]; then
                has_conflicts=true
            fi

            if [ "$days_open" -gt "$STALE_PR_DAYS" ] || [ "$review_count" -eq 0 ] || [ "$has_conflicts" = "true" ]; then
                pr_obj=$(jq -n \
                    --arg repo "$repo_name" \
                    --argjson pr_number "$pr_number" \
                    --arg title "$pr_title" \
                    --arg author "$pr_author" \
                    --argjson days_open "$days_open" \
                    --argjson draft "$draft" \
                    --arg requested_reviewers "$requested_reviewers" \
                    --arg approved_by "$approved_by" \
                    --arg changes_requested_by "$changes_requested_by" \
                    --arg waiting_on "$waiting_on" \
                    --argjson review_count "$review_count" \
                    --argjson has_conflicts "$has_conflicts" \
                    --arg html_url "$html_url" \
                    '{
                        repository: $repo,
                        pr_number: $pr_number,
                        title: $title,
                        author: $author,
                        days_open: $days_open,
                        draft: $draft,
                        requested_reviewers: (if $requested_reviewers == "" then [] else $requested_reviewers | split(",") end),
                        approved_by: (if $approved_by == "" then [] else $approved_by | split(",") end),
                        changes_requested_by: (if $changes_requested_by == "" then [] else $changes_requested_by | split(",") end),
                        waiting_on: (if $waiting_on == "" then [] else $waiting_on | split(",") end),
                        review_count: $review_count,
                        has_merge_conflicts: $has_conflicts,
                        html_url: $html_url
                    }')
                all_stale_prs=$(echo "$all_stale_prs" | jq --argjson obj "$pr_obj" '. + [$obj]')
                total_stale=$((total_stale + 1))
            fi

            if [ "$review_count" -eq 0 ] && [ "$draft" != "true" ]; then
                u_obj=$(jq -n --arg repo "$repo_name" --argjson pr_number "$pr_number" --arg title "$pr_title" --arg author "$pr_author" --argjson days_open "$days_open" --arg html_url "$html_url" '{repository: $repo, pr_number: $pr_number, title: $title, author: $author, days_open: $days_open, html_url: $html_url}')
                all_unreviewed_prs=$(echo "$all_unreviewed_prs" | jq --argjson obj "$u_obj" '. + [$obj]')
                total_unreviewed=$((total_unreviewed + 1))
            fi

            if [ "$has_conflicts" = "true" ]; then
                c_obj=$(jq -n --arg repo "$repo_name" --argjson pr_number "$pr_number" --arg title "$pr_title" --arg author "$pr_author" --argjson days_open "$days_open" --arg html_url "$html_url" '{repository: $repo, pr_number: $pr_number, title: $title, author: $author, days_open: $days_open, html_url: $html_url}')
                all_conflict_prs=$(echo "$all_conflict_prs" | jq --argjson obj "$c_obj" '. + [$obj]')
                total_conflicts=$((total_conflicts + 1))
            fi

        done <<< $(echo "$prs_json" | jq -c '.[]')

        sleep 0.3
    fi
done <<< "$repositories"

cat << EOF
{
    "repositories_analyzed": $repos_analyzed,
    "total_open_prs": $total_open_prs,
    "stale_prs_count": $total_stale,
    "unreviewed_prs_count": $total_unreviewed,
    "conflict_prs_count": $total_conflicts,
    "stale_threshold_days": $STALE_PR_DAYS,
    "stale_prs": $all_stale_prs,
    "unreviewed_prs": $all_unreviewed_prs,
    "conflict_prs": $all_conflict_prs,
    "report_time": "$NOW_ISO"
}
EOF