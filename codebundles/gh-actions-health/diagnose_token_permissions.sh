#!/bin/bash

# Diagnostic script to check GITHUB_TOKEN permissions
# This helps identify why log access is failing

set -e

# Function to handle error messages and exit
function error_exit {
    echo "Error: $1" >&2
    exit 1
}

# Check required environment variables
if [ -z "$GITHUB_TOKEN" ]; then
    error_exit "GITHUB_TOKEN is required"
fi

# Build the headers array for curl
HEADERS=()
if [ -n "$GITHUB_TOKEN" ]; then
    HEADERS+=(-H "Authorization: token $GITHUB_TOKEN")
fi
HEADERS+=(-H "Accept: application/vnd.github.v3+json")

echo "=== GitHub Token Permissions Diagnostic ===" >&2

# Test 1: Basic authentication
echo "1. Testing basic authentication..." >&2
auth_response=$(curl -sS "${HEADERS[@]}" "https://api.github.com/user")
if echo "$auth_response" | jq -e '.login' >/dev/null 2>&1; then
    username=$(echo "$auth_response" | jq -r '.login')
    echo "   ✓ Authentication successful for user: $username" >&2
else
    echo "   ✗ Authentication failed" >&2
    echo "   Response: $auth_response" >&2
    exit 1
fi

# Test 2: Check token type and scopes
echo "2. Checking token type and scopes..." >&2
# Try to get rate limit info which includes token info
rate_response=$(curl -sS -I "${HEADERS[@]}" "https://api.github.com/rate_limit")
token_scopes=$(echo "$rate_response" | grep -i "x-oauth-scopes:" | cut -d: -f2- | tr -d ' \r\n' || echo "unknown")
echo "   Token scopes: $token_scopes" >&2

# Test 3: Try to access a specific repository's actions
echo "3. Testing repository access..." >&2
if [ -n "$GITHUB_REPOS" ] && [ "$GITHUB_REPOS" != "ALL" ]; then
    # Use first repo from the list
    test_repo=$(echo "$GITHUB_REPOS" | cut -d',' -f1 | tr -d ' ')
    echo "   Testing access to repository: $test_repo" >&2
    
    # Test basic repo access
    repo_response=$(curl -sS "${HEADERS[@]}" "https://api.github.com/repos/$test_repo" 2>/dev/null)
    if echo "$repo_response" | jq -e '.name' >/dev/null 2>&1; then
        echo "   ✓ Repository access successful" >&2
    else
        echo "   ✗ Repository access failed" >&2
        echo "   Response: $repo_response" >&2
    fi
    
    # Test 4: Try to access workflow runs
    echo "4. Testing workflow runs access..." >&2
    runs_response=$(curl -sS "${HEADERS[@]}" "https://api.github.com/repos/$test_repo/actions/runs?per_page=1" 2>/dev/null)
    if echo "$runs_response" | jq -e '.workflow_runs' >/dev/null 2>&1; then
        echo "   ✓ Workflow runs access successful" >&2
        
        # Get a run ID for log testing
        run_id=$(echo "$runs_response" | jq -r '.workflow_runs[0].id // empty')
        if [ -n "$run_id" ] && [ "$run_id" != "null" ]; then
            echo "   Found workflow run ID: $run_id" >&2
            
            # Test 5: Try to access jobs for this run
            echo "5. Testing jobs access..." >&2
            jobs_response=$(curl -sS "${HEADERS[@]}" "https://api.github.com/repos/$test_repo/actions/runs/$run_id/jobs" 2>/dev/null)
            if echo "$jobs_response" | jq -e '.jobs' >/dev/null 2>&1; then
                echo "   ✓ Jobs access successful" >&2
                
                # Get a job ID for log testing
                job_id=$(echo "$jobs_response" | jq -r '.jobs[0].id // empty')
                if [ -n "$job_id" ] && [ "$job_id" != "null" ]; then
                    echo "   Found job ID: $job_id" >&2
                    
                    # Test 6: Try to access logs
                    echo "6. Testing log access..." >&2
                    log_response=$(curl -sS -I "${HEADERS[@]}" \
                        -H "Accept: application/vnd.github.v3.raw" \
                        "https://api.github.com/repos/$test_repo/actions/jobs/$job_id/logs" 2>/dev/null)
                    
                    http_code=$(echo "$log_response" | head -n1 | awk '{print $2}')
                    echo "   HTTP response code: $http_code" >&2
                    
                    case $http_code in
                        200)
                            echo "   ✓ Log access successful!" >&2
                            ;;
                        403)
                            echo "   ✗ Log access forbidden (403) - insufficient permissions" >&2
                            echo "   This means the token lacks 'actions:read' permission" >&2
                            ;;
                        404)
                            echo "   ✗ Logs not found (404) - logs may have expired or job may not have logs" >&2
                            ;;
                        *)
                            echo "   ✗ Unexpected response: $http_code" >&2
                            ;;
                    esac
                else
                    echo "   ✗ No job ID found" >&2
                fi
            else
                echo "   ✗ Jobs access failed" >&2
                echo "   Response: $jobs_response" >&2
            fi
        else
            echo "   ✗ No workflow run ID found" >&2
        fi
    else
        echo "   ✗ Workflow runs access failed" >&2
        echo "   Response: $runs_response" >&2
    fi
else
    echo "   Skipping repository-specific tests (no specific repos configured)" >&2
fi

echo "=== Diagnostic Complete ===" >&2

# Output summary JSON
cat << EOF
{
    "authentication": "successful",
    "username": "$username",
    "token_scopes": "$token_scopes",
    "diagnostic_complete": true,
    "recommendations": [
        "If log access failed with 403, the token needs 'actions:read' permission",
        "Check if the repository has restricted GITHUB_TOKEN permissions",
        "Consider using a Personal Access Token with 'repo' and 'actions:read' scopes",
        "Verify the token has access to private repositories if applicable"
    ]
}
EOF 