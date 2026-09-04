#!/bin/bash

set -e
source "$(dirname "$0")/_github_auth.sh"

function perform_curl {
    local url="$1"
    local response
    response=$(curl -sS "${HEADERS[@]}" "$url") || error_exit "Failed to perform curl request to $url"
    echo "$response"
}

PULSE_DAYS=${PULSE_DAYS:-7}
INACTIVE_THRESHOLD_DAYS=${INACTIVE_THRESHOLD_DAYS:-14}
current_time=$(date +%s)
since_date=$(date -d "$PULSE_DAYS days ago" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "Building contributor activity pulse (looking back ${PULSE_DAYS} days)..." >&2

repositories=$(get_repositories_to_analyze)

declare -A contributor_commits
declare -A contributor_prs
declare -A contributor_repos
declare -A contributor_last_commit
declare -A contributor_last_commit_date

all_review_bottlenecks="[]"
all_inactive="[]"
waiting_on_map="{}"
repos_analyzed=0

while IFS= read -r repo_name; do
    if [ -n "$repo_name" ]; then
        repos_analyzed=$((repos_analyzed + 1))
        echo "Processing repository: $repo_name" >&2

        commits_json=$(perform_curl "https://api.github.com/repos/$repo_name/commits?since=$since_date&per_page=100" 2>/dev/null || echo "[]")

        if echo "$commits_json" | jq -e 'type == "array"' >/dev/null 2>>/dev/null 2>&1 ]; then1; then
            while IFS= read -r commit; do
                if [ -z "$commit" ] || [ "$commit" = "null" ]; then continue; fi
                author_login=$(echo "$commit" | jq -r '.author.login // ""')
                commit_date=$(echo "$commit" | jq -r '.commit.author.date // ""')

                if [ -n "$author_login" ] && [ "$author_login" != "null" ] && [ "$author_login" != "" ]; then
                    current_commits=${contributor_commits["$author_login"]:-0}
                    contributor_commits["$author_login"]=$((current_commits + 1))

                    current_prs=${contributor_prs["$author_login"]:-0}
                    contributor_prs["$author_login"]=$current_prs

                    existing_repos=${contributor_repos["$author_login"]:-""}
                    if ! echo "$existing_repos" | grep -q "$repo_name"; then
                        if [ -z "$existing_repos" ]; then
                            contributor_repos["$author_login"]="$repo_name"
                        else
                            contributor_repos["$author_login"]="$existing_repos,$repo_name"
                        fi
                    fi

                    if [ -n "$commit_date" ]; then
                        existing_date=${contributor_last_commit_date["$author_login"]:-""}
                        if [ -z "$existing_date" ] || [ "$commit_date" \> "$existing_date" ]; then
                            contributor_last_commit_date["$author_login"]="$commit_date"
                            contributor_last_commit["$author_login"]="$repo_name"
                        fi
                    fi
                fi
            done <<< $(echo "$commits_json" | jq -c '.[]')
        fi

        prs_json=$(perform_curl "https://api.github.com/repos/$repo_name/pulls?state=open&per_page=100" 2>/dev/null || echo "[]")

        if echo "$prs_json" | jq -e 'type == "array"' >/dev/null 2>>/dev/null 2>&1 ]; then1; then
            while IFS= read -r pr; do
                if [ -z "$pr" ] || [ "$pr" = "null" ]; then continue; fi
                pr_author=$(echo "$pr" | jq -r '.user.login // ""')
                pr_number=$(echo "$pr" | jq -r '.number')
                pr_title=$(echo "$pr" | jq -r '.title')
                created_at=$(echo "$pr" | jq -r '.created_at // ""')
                html_url=$(echo "$pr" | jq -r '.html_url // ""')

                if [ -n "$pr_author" ] && [ "$pr_author" != "null" ] && [ "$pr_author" != "" ]; then
                    current_prs=${contributor_prs["$pr_author"]:-0}
                    contributor_prs["$pr_author"]=$((current_prs + 1))

                    existing_repos=${contributor_repos["$pr_author"]:-""}
                    if ! echo "$existing_repos" | grep -q "$repo_name"; then
                        if [ -z "$existing_repos" ]; then
                            contributor_repos["$pr_author"]="$repo_name"
                        else
                            contributor_repos["$pr_author"]="$existing_repos,$repo_name"
                        fi
                    fi
                fi

                requested_reviewers=$(echo "$pr" | jq -r '[.requested_reviewers[]?.login] | join(",")')
                if [ -n "$requested_reviewers" ] && [ "$requested_reviewers" != "" ]; then
                    created_timestamp=$(date -d "$created_at" +%s 2>/dev/null || echo "0")
                    days_open=0
                    if [ "$created_timestamp" != "0" ]; then
                        days_open=$(( (current_time - created_timestamp) / 86400 ))
                    fi

                    reviews_json=$(perform_curl "https://api.github.com/repos/$repo_name/pulls/$pr_number/reviews?per_page=20" 2>/dev/null || echo "[]")
                    approved_by=$(echo "$reviews_json" | jq -r '[.[] | select(.state == "APPROVED") | .user.login] | unique | join(",")')
                    changes_requested_by=$(echo "$reviews_json" | jq -r '[.[] | select(.state == "CHANGES_REQUESTED") | .user.login] | unique | join(",")')

                    block=false
                    IFS=',' read -ra REQ_ARRAY <<< "$requested_reviewers"
                    for req in "${REQ_ARRAY[@]}"; do
                        req_trimmed=$(echo "$req" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                        if [ -z "$req_trimmed" ]; then continue; fi
                        if ! echo "$approved_by" | grep -q "$req_trimmed" && ! echo "$changes_requested_by" | grep -q "$req_trimmed"; then
                            block=true

                            existing_waiting=$(echo "$waiting_on_map" | jq -r --arg login "$req_trimmed" '.[$login] // []')
                            pr_waiting_obj=$(jq -n \
                                --arg repo "$repo_name" \
                                --argjson pr "$pr_number" \
                                --arg title "$pr_title" \
                                --arg author "$pr_author" \
                                --argjson days_waiting "$days_open" \
                                '{
                                    repo: $repo,
                                    pr: $pr,
                                    title: $title,
                                    author: $author,
                                    days_waiting: $days_waiting
                                }')
                            updated_waiting=$(echo "$existing_waiting" | jq --argjson obj "$pr_waiting_obj" '. + [$obj]')
                            waiting_on_map=$(echo "$waiting_on_map" | jq --arg login "$req_trimmed" --argjson arr "$updated_waiting" '.[$login] = $arr')
                        fi
                    done

                    if [ "$block" = "true" ]; then
                        bottleneck_obj=$(jq -n \
                            --arg repo "$repo_name" \
                            --argjson pr_number "$pr_number" \
                            --arg title "$pr_title" \
                            --arg author "$pr_author" \
                            --argjson days_open "$days_open" \
                            --arg requested_reviewers "$requested_reviewers" \
                            --arg approved_by "$approved_by" \
                            --arg changes_requested_by "$changes_requested_by" \
                            --argjson blocked true \
                            --arg html_url "$html_url" \
                            '{
                                repository: $repo,
                                pr_number: $pr_number,
                                title: $title,
                                author: $author,
                                days_open: $days_open,
                                requested_reviewers: (if $requested_reviewers == "" then [] else $requested_reviewers | split(",") end),
                                reviewers_who_approved: (if $approved_by == "" then [] else $approved_by | split(",") end),
                                reviewers_who_have_not_responded: (if $requested_reviewers == "" then [] else ($requested_reviewers | split(",")) - (if $approved_by == "" then [] else $approved_by | split(",") end) - (if $changes_requested_by == "" then [] else $changes_requested_by | split(",") end) end),
                                blocked: true,
                                html_url: $html_url
                            }')
                        all_review_bottlenecks=$(echo "$all_review_bottlenecks" | jq --argjson obj "$bottleneck_obj" '. + [$obj]')
                    fi

                fi
            done <<< $(echo "$prs_json" | jq -c '.[]')
        fi

        sleep 0.5
    fi
done <<< "$repositories"

contributors_active="[]"
for login in "${!contributor_commits[@]}"; do
    entry=$(jq -n \
        --arg login "$login" \
        --argjson commits "${contributor_commits[$login]:-0}" \
        --argjson prs "${contributor_prs[$login]:-0}" \
        --arg repos "${contributor_repos[$login]:-}" \
        --arg last_commit "${contributor_last_commit_date[$login]:-}" \
        --arg last_repo "${contributor_last_commit[$login]:-}" \
        '{
            login: $login,
            repos_active: (if $repos == "" then 0 else $repos | split(",") | length end),
            commits_pushed: $commits,
            prs_opened: $prs,
            most_recent_commit: $last_commit,
            repositories: (if $repos == "" then [] else $repos | split(",") end)
        }')
    contributors_active=$(echo "$contributors_active" | jq --argjson obj "$entry" '. + [$obj]')
done

for login in "${!contributor_prs[@]}"; do
    if [ -z "${contributor_commits[$login]}" ]; then
        entry=$(jq -n \
            --arg login "$login" \
            --argjson commits 0 \
            --argjson prs "${contributor_prs[$login]:-0}" \
            --arg repos "${contributor_repos[$login]:-}" \
            --arg last_commit "${contributor_last_commit_date[$login]:-}" \
            --arg last_repo "${contributor_last_commit[$login]:-}" \
            '{
                login: $login,
                repos_active: (if $repos == "" then 0 else $repos | split(",") | length end),
                commits_pushed: $commits,
                prs_opened: $prs,
                most_recent_commit: $last_commit,
                repositories: (if $repos == "" then [] else $repos | split(",") end)
            }')
        contributors_active=$(echo "$contributors_active" | jq --argjson obj "$entry" '. + [$obj]')
    fi
done

all_contributors=$(echo "$contributors_active" | jq '[.[].login] | unique')

echo "Pulse complete: $(echo "$all_contributors" | jq 'length') contributors, $(echo "$all_review_bottlenecks" | jq 'length') review bottlenecks" >&2

cat << EOF
{
    "report_period_days": $PULSE_DAYS,
    "repositories_analyzed": $repos_analyzed,
    "contributors": $contributors_active,
    "total_active_contributors": $(echo "$contributors_active" | jq 'length'),
    "review_bottlenecks": $all_review_bottlenecks,
    "waiting_on_summary": $waiting_on_map,
    "report_time": "$NOW_ISO"
}
EOF