#!/bin/bash

set -e
source "$(dirname "$0")/_github_auth.sh"

function perform_curl {
    local url="$1"
    local expected_status="${2:-200}"
    local response
    response=$(curl -sS -w "\n%{http_code}" "${HEADERS[@]}" "$url") || echo ""
    echo "$response"
}

NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "Auditing repository configuration health across repositories..." >&2

repositories=$(get_repositories_to_analyze)

all_findings="[]"
repos_analyzed=0
repos_with_issues=0
total_checks_passed=0
total_checks_possible=0

while IFS= read -r repo_name; do
    if [ -n "$repo_name" ]; then
        repos_analyzed=$((repos_analyzed + 1))
        echo "Checking config for repository: $repo_name" >&2

        repo_json=$(perform_curl "https://api.github.com/repos/$repo_name")
        repo_json=$(echo "$repo_json")

        has_issues=$(echo "$repo_json" | jq -r '.has_issues // false')
        has_wiki=$(echo "$repo_json" | jq -r '.has_wiki // false')
        archived=$(echo "$repo_json" | jq -r '.archived // false')
        description=$(echo "$repo_json" | jq -r '.description // ""')
        license_spdx=$(echo "$repo_json" | jq -r '.license.spdx_id // ""')
        default_branch=$(echo "$repo_json" | jq -r '.default_branch // "main"')

        readme_status=false
        readme_resp=$(perform_curl "https://api.github.com/repos/$repo_name/contents/README.md")
        readme_resp=$(echo "$readme_resp")
        readme_size=0
        if echo "$readme_resp" | jq -e '.size' >/dev/null 2>&1; then
            readme_size=$(echo "$readme_resp" | jq -r '.size // 0')
        fi
        if [ "$readme_size" -gt 100 ]; then readme_status=true; fi

        license_status=false
        if [ -n "$license_spdx" ] && [ "$license_spdx" != "null" ] && [ "$license_spdx" != "NOASSERTION" ]; then
            license_status=true
        fi

        desc_status=false
        if [ -n "$description" ] && [ "$description" != "null" ] && [ "$description" != "" ]; then
            desc_status=true
        fi

        contributing_status=false
        contrib_resp=$(perform_curl "https://api.github.com/repos/$repo_name/contents/CONTRIBUTING.md")
        contrib_resp=$(echo "$contrib_resp")
        if echo "$contrib_resp" | jq -e '.size' >/dev/null 2>&1; then
            contributing_status=true
        fi

        codeowners_status=false
        co_resp=$(perform_curl "https://api.github.com/repos/$repo_name/contents/.github/CODEOWNERS")
        co_resp=$(echo "$co_resp")
        if echo "$co_resp" | jq -e '.size' >/dev/null 2>&1; then
            codeowners_status=true
        fi

        branch_protection_status=false
        bp_resp=$(perform_curl "https://api.github.com/repos/$repo_name/branches/$default_branch/protection")
        bp_resp=$(echo "$bp_resp")
        if echo "$bp_resp" | jq -e '.url' >/dev/null 2>&1; then
            branch_protection_status=true
        fi

        community_score=0
        community_resp=$(perform_curl "https://api.github.com/repos/$repo_name/community/profile")
        community_resp=$(echo "$community_resp")
        if echo "$community_resp" | jq -e '.health_percentage' >/dev/null 2>&1; then
            community_score=$(echo "$community_resp" | jq -r '.health_percentage // 0')
        fi

        checks_total=7
        checks_passed=0
        check_results=""
        if [ "$readme_status" = "true" ]; then checks_passed=$((checks_passed + 1)); check_results="$check_results README:pass"; else check_results="$check_results README:fail"; fi
        if [ "$license_status" = "true" ]; then checks_passed=$((checks_passed + 1)); check_results="$check_results LICENSE:pass"; else check_results="$check_results LICENSE:fail"; fi
        if [ "$desc_status" = "true" ]; then checks_passed=$((checks_passed + 1)); check_results="$check_results DESC:pass"; else check_results="$check_results DESC:fail"; fi
        if [ "$contributing_status" = "true" ]; then checks_passed=$((checks_passed + 1)); check_results="$check_results CONTRIBUTING:pass"; else check_results="$check_results CONTRIBUTING:fail"; fi
        if [ "$codeowners_status" = "true" ]; then checks_passed=$((checks_passed + 1)); check_results="$check_results CODEOWNERS:pass"; else check_results="$check_results CODEOWNERS:fail"; fi
        if [ "$branch_protection_status" = "true" ]; then checks_passed=$((checks_passed + 1)); check_results="$check_results BRANCH_PROT:pass"; else check_results="$check_results BRANCH_PROT:fail"; fi
        if [ "$community_score" -ge 70 ]; then checks_passed=$((checks_passed + 1)); check_results="$check_results COMMUNITY:pass"; else check_results="$check_results COMMUNITY:fail($community_score)"; fi

        total_checks_passed=$((total_checks_passed + checks_passed))
        total_checks_possible=$((total_checks_possible + checks_total))

        health_score=$(echo "scale=2; $checks_passed / $checks_total" | bc -l)
        if [[ "$health_score" == .* ]]; then health_score="0$health_score"; fi

        if [ "$checks_passed" -lt "$checks_total" ]; then
            repos_with_issues=$((repos_with_issues + 1))
        fi

        finding=$(jq -n \
            --arg repo "$repo_name" \
            --argjson readonly "$readme_status" \
            --argjson license "$license_status" \
            --argjson description "$desc_status" \
            --argjson contributing "$contributing_status" \
            --argjson codeowners "$codeowners_status" \
            --argjson branch_protection "$branch_protection_status" \
            --argjson archived "$archived" \
            --argjson community_score "$community_score" \
            --arg health_score "$health_score" \
            --arg check_results "$(echo "$check_results" | sed 's/^[[:space:]]*//')" \
            '{
                repository: $repo,
                checks: {
                    readme: $readonly,
                    license: $license,
                    description: $description,
                    contributing: $contributing,
                    codeowners: $codeowners,
                    branch_protection: $branch_protection,
                    archived: $archived
                },
                community_profile_score: $community_score,
                health_score: $health_score,
                check_summary: $check_results
            }')
        all_findings=$(echo "$all_findings" | jq --argjson obj "$finding" '. + [$obj]')

        echo "Repository $repo_name: health_score=$health_score ($checks_passed/$checks_total checks passed)" >&2

        sleep 0.3
    fi
done <<< "$repositories"

overall_health=1.0
if [ "$total_checks_possible" -gt 0 ]; then
    overall_health=$(echo "scale=2; $total_checks_passed / $total_checks_possible" | bc -l)
    if [[ "$overall_health" == .* ]]; then overall_health="0$overall_health"; fi
fi

cat << EOF
{
    "repositories_analyzed": $repos_analyzed,
    "repos_with_config_issues": $repos_with_issues,
    "overall_health_score": $overall_health,
    "findings": $all_findings,
    "report_time": "$NOW_ISO"
}
EOF