#!/bin/bash
# set -x
# Check if required environment variables are set
if [ -z "${JENKINS_URL}" ] || [ -z "${JENKINS_USERNAME}" ] || [ -z "${JENKINS_TOKEN}" ]; then
    echo "Please set JENKINS_URL, JENKINS_USERNAME, and JENKINS_TOKEN environment variables."
    exit 1
fi

# Authentication string for curl
AUTH_HEADER="${JENKINS_USERNAME}:${JENKINS_TOKEN}"

# Temporary file for JSON output
OUTPUT_FILE="faild_build_logs.json"

# Fetch Jenkins jobs data
jenkins_data=$(curl -s -u "${AUTH_HEADER}" "${JENKINS_URL}/api/json?depth=2")


# Validate if Jenkins data was retrieved successfully
if [ -z "$jenkins_data" ]; then
    echo "Failed to fetch data from Jenkins. Please check your credentials or URL."
    exit 1
fi

# Start JSON array
echo "[" > "$OUTPUT_FILE"
first_entry=true

# Process each job with a failed last build
echo "$jenkins_data" | jq -c '.jobs[] | select(.lastBuild.result == "FAILURE") | {name: .name, url: .lastBuild.url, number: .lastBuild.number}' | \
while read -r job_info; do
    # Extract job details
    job_name=$(echo "$job_info" | jq -r '.name')
    build_url=$(echo "$job_info" | jq -r '.url')
    build_number=$(echo "$job_info" | jq -r '.number')

    # Skip if any of the required fields are missing
    if [ -z "$job_name" ] || [ -z "$build_url" ] || [ -z "$build_number" ]; then
        echo "Skipping a job due to missing information."
        continue
    fi

    # Fetch build logs
    logs=$(curl -s -u "$AUTH_HEADER" "${build_url}logText/progressiveText?start=0")
    if [ $? -ne 0 ]; then
        echo "Failed to fetch logs for job: $job_name, build: $build_number."
        continue
    fi

    # Escape special characters in logs for JSON
    escaped_logs=$(echo "$logs" | jq -sR .)

    # Add comma if not the first entry
    if [ "$first_entry" = false ]; then
        echo "," >> "$OUTPUT_FILE"
    fi
    first_entry=false

    # Write JSON entry to file
    cat << EOF >> "$OUTPUT_FILE"
{
    "job_name": "$job_name",
    "result": "FAILURE",
    "build_number": $build_number,
    "logs": $escaped_logs,
    "url": "$build_url"
}
EOF
done

# Close JSON array
echo "]" >> "$OUTPUT_FILE"

# Validate JSON and pretty-print the output
if jq empty "$OUTPUT_FILE" > /dev/null 2>&1; then
    cat "$OUTPUT_FILE"
    # echo "Failed builds data has been saved to $OUTPUT_FILE"
else
    echo "Error: Invalid JSON generated. Check the output file for issues."
    exit 1
fi
