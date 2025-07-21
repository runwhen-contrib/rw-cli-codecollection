#!/bin/bash

# Debug script to investigate log access issues
# This helps identify why logs appear empty despite having workflow permissions

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

echo "=== GitHub Actions Log Access Debug ===" >&2

# Test with a specific failed run from your data
test_repos=(
    "runwhen/infra-flux-dev-panda"
    "runwhen/platform-robot-runtime"
    "runwhen/runwhen-runner"
)

# Test with specific run IDs from your failures
test_runs=(
    "15699364732:runwhen/infra-flux-dev-panda"
    "15716134222:runwhen/platform-robot-runtime"
    "15714964652:runwhen/runwhen-runner"
)

for run_info in "${test_runs[@]}"; do
    run_id="${run_info%%:*}"
    repo="${run_info##*:}"
    
    echo "=== Testing Run ID: $run_id in $repo ===" >&2
    
    # 1. Get run details
    echo "1. Getting run details..." >&2
    run_response=$(curl -sS "${HEADERS[@]}" "https://api.github.com/repos/$repo/actions/runs/$run_id")
    
    if echo "$run_response" | jq -e '.id' >/dev/null 2>&1; then
        status=$(echo "$run_response" | jq -r '.status')
        conclusion=$(echo "$run_response" | jq -r '.conclusion')
        created_at=$(echo "$run_response" | jq -r '.created_at')
        echo "   Run Status: $status, Conclusion: $conclusion, Created: $created_at" >&2
    else
        echo "   ❌ Failed to get run details" >&2
        echo "   Response: $run_response" >&2
        continue
    fi
    
    # 2. Get jobs for this run
    echo "2. Getting jobs..." >&2
    jobs_response=$(curl -sS "${HEADERS[@]}" "https://api.github.com/repos/$repo/actions/runs/$run_id/jobs")
    
    if echo "$jobs_response" | jq -e '.jobs' >/dev/null 2>&1; then
        job_count=$(echo "$jobs_response" | jq '.jobs | length')
        echo "   Found $job_count jobs" >&2
        
        # Get first failed job
        failed_job=$(echo "$jobs_response" | jq -r '.jobs[] | select(.conclusion == "failure") | . | @base64' | head -n1)
        
        if [ -n "$failed_job" ]; then
            job_data=$(echo "$failed_job" | base64 --decode)
            job_id=$(echo "$job_data" | jq -r '.id')
            job_name=$(echo "$job_data" | jq -r '.name')
            job_started_at=$(echo "$job_data" | jq -r '.started_at')
            job_completed_at=$(echo "$job_data" | jq -r '.completed_at')
            
            echo "   Testing job: $job_name (ID: $job_id)" >&2
            echo "   Job started: $job_started_at, completed: $job_completed_at" >&2
            
            # 3. Test different log access methods
            echo "3. Testing log access methods..." >&2
            
            # Method 1: Check if logs exist (HEAD request)
            echo "   Method 1: HEAD request to check log existence..." >&2
            head_response=$(curl -sS -I "${HEADERS[@]}" \
                -H "Accept: application/vnd.github.v3.raw" \
                "https://api.github.com/repos/$repo/actions/jobs/$job_id/logs" 2>/dev/null || echo "HTTP/1.1 000 Error")
            
            http_code=$(echo "$head_response" | head -n1 | awk '{print $2}')
            content_length=$(echo "$head_response" | grep -i "content-length:" | cut -d: -f2 | tr -d ' \r\n' || echo "unknown")
            echo "      HTTP Code: $http_code" >&2
            echo "      Content-Length: $content_length" >&2
            
            # Method 2: Try to get actual logs
            echo "   Method 2: GET request for actual logs..." >&2
            log_response=$(curl -sS "${HEADERS[@]}" \
                -H "Accept: application/vnd.github.v3.raw" \
                "https://api.github.com/repos/$repo/actions/jobs/$job_id/logs" 2>/dev/null || echo "ERROR_FETCHING_LOGS")
            
            log_size=${#log_response}
            echo "      Response size: $log_size bytes" >&2
            
            if [ "$log_response" = "ERROR_FETCHING_LOGS" ]; then
                echo "      ❌ Error fetching logs" >&2
            elif [ $log_size -eq 0 ]; then
                echo "      ⚠️ Empty log response" >&2
            elif [ $log_size -lt 50 ]; then
                echo "      ⚠️ Very small log response: '$log_response'" >&2
            else
                echo "      ✅ Got log data ($log_size bytes)" >&2
                echo "      First 200 chars: $(echo "$log_response" | head -c 200)..." >&2
            fi
            
            # Method 3: Check log download URL
            echo "   Method 3: Checking for log download URL..." >&2
            download_url=$(echo "$job_data" | jq -r '.logs_url // empty')
            if [ -n "$download_url" ]; then
                echo "      Found logs_url: $download_url" >&2
                
                # Try the download URL
                download_response=$(curl -sS "${HEADERS[@]}" "$download_url" 2>/dev/null || echo "ERROR_DOWNLOAD")
                download_size=${#download_response}
                echo "      Download response size: $download_size bytes" >&2
                
                if [ $download_size -gt 50 ]; then
                    echo "      ✅ Download URL works" >&2
                fi
            else
                echo "      ⚠️ No logs_url found in job data" >&2
            fi
            
            # 4. Check job age and retention
            echo "4. Checking log retention..." >&2
            if [ "$job_completed_at" != "null" ] && [ -n "$job_completed_at" ]; then
                completion_timestamp=$(date -d "$job_completed_at" +%s 2>/dev/null || echo "0")
                current_timestamp=$(date +%s)
                age_days=$(( (current_timestamp - completion_timestamp) / 86400 ))
                echo "   Job completed $age_days days ago" >&2
                
                if [ $age_days -gt 90 ]; then
                    echo "   ⚠️ Job is older than typical log retention period (90 days)" >&2
                elif [ $age_days -gt 30 ]; then
                    echo "   ⚠️ Job is quite old, logs might be archived" >&2
                else
                    echo "   ✅ Job is recent, logs should be available" >&2
                fi
            fi
            
            # 5. Check if job actually ran or failed early
            echo "5. Checking job execution..." >&2
            steps=$(echo "$job_data" | jq '.steps[]')
            step_count=$(echo "$job_data" | jq '.steps | length')
            echo "   Job has $step_count steps" >&2
            
            if [ $step_count -eq 0 ]; then
                echo "   ⚠️ Job has no steps - might have failed before execution" >&2
            else
                # Check if any steps actually started
                started_steps=$(echo "$job_data" | jq '[.steps[] | select(.started_at != null)] | length')
                echo "   $started_steps steps actually started" >&2
                
                if [ $started_steps -eq 0 ]; then
                    echo "   ⚠️ No steps started - job failed before execution, no logs expected" >&2
                fi
            fi
            
        else
            echo "   ❌ No failed jobs found" >&2
        fi
    else
        echo "   ❌ Failed to get jobs" >&2
        echo "   Response: $jobs_response" >&2
    fi
    
    echo "" >&2
done

echo "=== Debug Complete ===" >&2

# Summary
cat << EOF
{
    "debug_complete": true,
    "tested_runs": [
        $(printf '"%s",' "${test_runs[@]}" | sed 's/,$//')
    ],
    "recommendations": [
        "Check if jobs completed successfully vs failed early",
        "Verify log retention periods for older jobs",
        "Test with more recent workflow failures",
        "Check if workflow-level failures have no job logs"
    ]
}
EOF 