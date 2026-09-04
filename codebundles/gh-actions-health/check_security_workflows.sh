#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e
source "$(dirname "$0")/_github_auth.sh"

# Function to handle error messages and exit

# Function to perform curl requests with error handling
function perform_curl {
    local url="$1"
    local response
    response=$(curl -sS "${HEADERS[@]}" "$url") || error_exit "Failed to perform curl request to $url"
    echo "$response"
}

# Default values
LOOKBACK_DAYS=${FAILURE_LOOKBACK_DAYS:-7}

echo "Checking security workflow status across specified repositories..." >&2

# Calculate the date threshold
date_threshold=$(date -d "$LOOKBACK_DAYS days ago" -u +%Y-%m-%dT%H:%M:%SZ)

# Get repositories to analyze
repositories=$(get_repositories_to_analyze)

# Initialize results
all_security_workflows="[]"
all_failed_security_workflows="[]"
all_security_alerts="{}"
total_critical_vulnerabilities=0
total_high_vulnerabilities=0

# Process each repository
while IFS= read -r repo_name; do
    if [ -n "$repo_name" ]; then
        echo "Checking repository: $repo_name" >&2
        
        # Get workflow runs for security-related workflows
        runs_json=$(perform_curl "https://api.github.com/repos/$repo_name/actions/runs?created=>$date_threshold&per_page=100" || echo '{"workflow_runs":[]}')
        
        # Check if the response contains workflow runs
        if echo "$runs_json" | jq -e '.workflow_runs' >/dev/null 2>&1; then
            # Filter for security-related workflows (by common naming patterns)
            security_workflows=$(echo "$runs_json" | jq -r --arg repo "$repo_name" '[
                .workflow_runs[] |
                select(.name | test("(?i)(security|vuln|cve|dependabot|codeql|trivy|snyk|semgrep|bandit)")) |
                {
                    repository: $repo,
                    name: .name,
                    run_number: .run_number,
                    conclusion: .conclusion,
                    status: .status,
                    html_url: .html_url,
                    created_at: .created_at,
                    head_branch: .head_branch
                }
            ]')
            
            # Get failed security workflows
            failed_security_workflows=$(echo "$security_workflows" | jq --arg repo "$repo_name" '[.[] | select(.conclusion == "failure" or .conclusion == "cancelled") | . + {repository: $repo}]')
            
            # Merge with all results
            all_security_workflows=$(echo "$all_security_workflows $security_workflows" | jq -s 'add')
            all_failed_security_workflows=$(echo "$all_failed_security_workflows $failed_security_workflows" | jq -s 'add')
        fi
        
        # Get Dependabot alerts (if accessible)
        dependabot_alerts="[]"
        if curl -sS "${HEADERS[@]}" "https://api.github.com/repos/$repo_name/dependabot/alerts?state=open&per_page=100" &>/dev/null; then
            alerts_json=$(perform_curl "https://api.github.com/repos/$repo_name/dependabot/alerts?state=open&per_page=100" || echo "[]")
            dependabot_alerts=$(echo "$alerts_json" | jq -r '[
                .[] |
                {
                    package_name: .dependency.package.name,
                    vulnerability: .security_advisory.summary,
                    severity: .security_advisory.severity,
                    cve_id: .security_advisory.cve_id,
                    url: .html_url,
                    state: .state
                }
            ]')
            
            # Count vulnerabilities by severity
            repo_critical=$(echo "$dependabot_alerts" | jq '[.[] | select(.severity == "critical")] | length')
            repo_high=$(echo "$dependabot_alerts" | jq '[.[] | select(.severity == "high")] | length')
            total_critical_vulnerabilities=$((total_critical_vulnerabilities + repo_critical))
            total_high_vulnerabilities=$((total_high_vulnerabilities + repo_high))
        fi
        
        # Get security advisories (if accessible)
        security_advisories="[]"
        if curl -sS "${HEADERS[@]}" "https://api.github.com/repos/$repo_name/security-advisories?state=published&per_page=50" &>/dev/null; then
            advisories_json=$(perform_curl "https://api.github.com/repos/$repo_name/security-advisories?state=published&per_page=50" || echo "[]")
            security_advisories=$(echo "$advisories_json" | jq -r '[
                .[] |
                {
                    ghsa_id: .ghsa_id,
                    summary: .summary,
                    severity: .severity,
                    published_at: .published_at,
                    url: .html_url
                }
            ]')
        fi
        
        # Combine alerts for this repository
        repo_all_alerts=$(echo "$dependabot_alerts $security_advisories" | jq -s 'add // []')
        
        # Add to overall alerts object with repository as key
        all_security_alerts=$(echo "$all_security_alerts" | jq --arg repo "$repo_name" --argjson alerts "$repo_all_alerts" '. + {($repo): $alerts}')
        
        # Rate limiting protection
        sleep 0.3
    fi
done <<< "$repositories"

# Create the final JSON output
cat << EOF
{
    "repositories_analyzed": $(echo "$repositories" | jq -R . | jq -s .),
    "security_workflows": $all_security_workflows,
    "failed_security_workflows": $all_failed_security_workflows,
    "failed_security_workflows_count": $(echo "$all_failed_security_workflows" | jq 'length'),
    "security_alerts_by_repo": $all_security_alerts,
    "total_critical_vulnerabilities": $total_critical_vulnerabilities,
    "total_high_vulnerabilities": $total_high_vulnerabilities,
    "lookback_days": $LOOKBACK_DAYS,
    "date_threshold": "$date_threshold"
}
EOF 