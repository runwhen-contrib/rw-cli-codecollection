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
LOOKBACK_DAYS=${SLI_LOOKBACK_DAYS:-7}

# Calculate the date threshold
date_threshold=$(date -d "$LOOKBACK_DAYS days ago" -u +%Y-%m-%dT%H:%M:%SZ)

echo "Calculating security SLI across specified repositories since $date_threshold..." >&2

# Get repositories to analyze
repositories=$(get_repositories_to_analyze)

# Initialize aggregated metrics
total_repos=0
total_critical_vulnerabilities=0
total_high_vulnerabilities=0
total_medium_vulnerabilities=0
total_security_workflows=0
failed_security_workflows=0

# Process each repository
while IFS= read -r repo_name; do
    if [ -n "$repo_name" ]; then
        echo "Processing repository: $repo_name" >&2
        total_repos=$((total_repos + 1))
        
        # Check Dependabot alerts (vulnerabilities)
        if curl -sS "${HEADERS[@]}" "https://api.github.com/repos/$repo_name/dependabot/alerts?state=open&per_page=100" &>/dev/null; then
            alerts_json=$(perform_curl "https://api.github.com/repos/$repo_name/dependabot/alerts?state=open&per_page=100" || echo "[]")
            
            if [ "$(echo "$alerts_json" | jq 'type')" = "array" ]; then
                critical_count=$(echo "$alerts_json" | jq '[.[] | select(.security_advisory.severity == "critical")] | length')
                high_count=$(echo "$alerts_json" | jq '[.[] | select(.security_advisory.severity == "high")] | length')
                medium_count=$(echo "$alerts_json" | jq '[.[] | select(.security_advisory.severity == "medium")] | length')
                
                total_critical_vulnerabilities=$((total_critical_vulnerabilities + critical_count))
                total_high_vulnerabilities=$((total_high_vulnerabilities + high_count))
                total_medium_vulnerabilities=$((total_medium_vulnerabilities + medium_count))
            fi
        fi
        
        # Check security-related workflow runs
        runs_json=$(perform_curl "https://api.github.com/repos/$repo_name/actions/runs?created=>$date_threshold&per_page=100")
        
        if echo "$runs_json" | jq -e '.workflow_runs' >/dev/null 2>&1; then
            security_runs=$(echo "$runs_json" | jq '[.workflow_runs[] | select(.name | test("security|Security|CodeQL|Dependabot|vulnerability"; "i"))]')
            
            if [ "$(echo "$security_runs" | jq 'length')" -gt 0 ]; then
                security_count=$(echo "$security_runs" | jq 'length')
                failed_security_count=$(echo "$security_runs" | jq '[.[] | select(.conclusion == "failure" or .conclusion == "cancelled")] | length')
                
                total_security_workflows=$((total_security_workflows + security_count))
                failed_security_workflows=$((failed_security_workflows + failed_security_count))
        fi
        fi
        
        # Rate limiting protection
        sleep 0.2
    fi
    done <<< "$repositories"

# Calculate security score
if [ $total_repos -eq 0 ]; then
    security_score="1.0"
else
    # Security score factors:
    # - Critical vulnerabilities: -0.5 per critical
    # - High vulnerabilities: -0.1 per high
    # - Medium vulnerabilities: -0.05 per medium
    # - Failed security workflows: -0.2 per failure
    
    vulnerability_penalty=$(echo "scale=4; ($total_critical_vulnerabilities * 0.5) + ($total_high_vulnerabilities * 0.1) + ($total_medium_vulnerabilities * 0.05)" | bc -l)
    workflow_penalty=$(echo "scale=4; $failed_security_workflows * 0.2" | bc -l)
    total_penalty=$(echo "scale=4; $vulnerability_penalty + $workflow_penalty" | bc -l)
    
    security_score=$(echo "scale=4; 1.0 - $total_penalty" | bc -l)
    
    # Ensure score doesn't go below 0
    security_score=$(echo "if ($security_score < 0) 0 else $security_score" | bc -l)
    
    # Ensure leading zero for JSON compliance
    if [[ "$security_score" == .* ]]; then
        security_score="0$security_score"
    fi
fi

# Output the results as JSON
cat << EOF
{
    "security_score": $security_score,
    "total_repositories": $total_repos,
    "critical_vulnerabilities": $total_critical_vulnerabilities,
    "high_vulnerabilities": $total_high_vulnerabilities,
    "medium_vulnerabilities": $total_medium_vulnerabilities,
    "total_security_workflows": $total_security_workflows,
    "failed_security_workflows": $failed_security_workflows,
    "lookback_days": $LOOKBACK_DAYS
}
EOF