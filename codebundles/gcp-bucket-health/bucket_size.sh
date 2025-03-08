#!/bin/bash

SERVICE_ACCOUNT_KEY=$GOOGLE_APPLICATION_CREDENTIALS
# Function to convert bytes to terabytes using awk
bytes_to_tb() {
    awk "BEGIN {printf \"%.4f\", $1 / (1024^4)}"
}

# Function to convert bytes to gigabytes using awk
bytes_to_gb() {
    awk "BEGIN {printf \"%.4f\", $1 / (1024^3)}"
}

# Function to get an access token using the service account key
get_access_token() {
    local key_file=$1
    local email=$(jq -r .client_email $key_file)
    local key=$(jq -r .private_key $key_file | sed 's/\\n/\n/g')

    local header=$(echo -n '{"alg":"RS256","typ":"JWT"}' | openssl base64 -e -A | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    local now=$(date +%s)
    local exp=$(($now + 3600))
    local payload=$(echo -n "{\"iss\":\"$email\",\"scope\":\"https://www.googleapis.com/auth/cloud-platform\",\"aud\":\"https://oauth2.googleapis.com/token\",\"exp\":$exp,\"iat\":$now}" | openssl base64 -e -A | tr -d '=' | tr '/+' '_-' | tr -d '\n')

    local sig=$(echo -n "$header.$payload" | openssl dgst -sha256 -sign <(echo -n "$key") | openssl base64 -e -A | tr -d '=' | tr '/+' '_-' | tr -d '\n')

    local jwt="$header.$payload.$sig"

    local token=$(curl -s --request POST \
      --url https://oauth2.googleapis.com/token \
      --header "Content-Type: application/x-www-form-urlencoded" \
      --data "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=$jwt" | jq -r .access_token)
    echo $token
}

# Function to check if the Monitoring API is enabled
is_monitoring_api_enabled() {
    local project_id=$1
    local token=$2
    local response=$(curl -s -w "\nHTTP_STATUS:%{http_code}" --header "Authorization: Bearer $token" \
        "https://serviceusage.googleapis.com/v1/projects/$project_id/services/monitoring.googleapis.com")

    local http_status=$(echo "$response" | sed -n 's/.*HTTP_STATUS:\([0-9]*\)$/\1/p')
    local response_body=$(echo "$response" | sed -n '1,/^HTTP_STATUS:/p' | sed '$d')

    if [[ "$http_status" -ne 200 ]]; then
        echo "Error checking Monitoring API status for project $project_id:"
        echo "HTTP Status: $http_status"
        echo "Response: $response_body"
        return 1
    fi

    local state=$(echo "$response_body" | jq -r '.state')
    if [[ "$state" == "ENABLED" ]]; then
        return 0
    else
        echo "Monitoring API is not enabled for project $project_id."
        echo "State: $state"
        return 1
    fi
}

# Function to list buckets in a project
list_buckets() {
    local project_id=$1
    local token=$2
    local response=$(curl -s --header "Authorization: Bearer $token" \
        "https://storage.googleapis.com/storage/v1/b?project=$project_id")

    echo $response | jq -r '.items[].name'
}

# Function to get the size of a bucket using gsutil
get_bucket_size_gsutil() {
    local bucket_name=$1
    local access_token=$2
    local size_bytes=$(CLOUDSDK_AUTH_ACCESS_TOKEN=$access_token gsutil du -s "gs://$bucket_name" | awk '{print $1}')
    echo $size_bytes
}

# Function to get the sizes of all buckets using PromQL
get_all_bucket_sizes() {
    local project_id=$1
    local token=$2

    local response=$(curl -s --header "Authorization: Bearer $token" \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data 'query=sum by (bucket_name) (avg_over_time(storage_googleapis_com:storage_total_bytes{monitored_resource="gcs_bucket"}[30m]))' \
        "https://monitoring.googleapis.com/v1/projects/$project_id/location/global/prometheus/api/v1/query")

    echo $response | jq -r '.data.result[] | {bucket_name: .metric.bucket_name, size_bytes: .value[1]}'
}

# Function to get bucket metadata (including location and storage class)
get_bucket_metadata() {
    local bucket_name=$1
    local token=$2
    local response=$(curl -s --header "Authorization: Bearer $token" \
        "https://storage.googleapis.com/storage/v1/b/$bucket_name")

    echo $response
}

# Check if PROJECT_IDS environment variable is set and valid
if [ -z "$PROJECT_IDS" ]; then
    echo "Error: PROJECT_IDS environment variable is not set or empty."
    echo "Usage: export PROJECT_IDS='project_id1,project_id2,...'"
    exit 1
fi

# Read the PROJECT_IDS environment variable into an array
IFS=',' read -r -a projects <<< "$PROJECT_IDS"

# Get the access token using either the provided service account key or gcloud
if [ -n "$SERVICE_ACCOUNT_KEY" ]; then
    echo "SERVICE_ACCOUNT_KEY is set. Using it to get the access token."
    access_token=$(get_access_token "$SERVICE_ACCOUNT_KEY")
else
    echo "SERVICE_ACCOUNT_KEY is not set. Attempting to set access token using gcloud."
    access_token=$(gcloud auth application-default print-access-token)
    if [ -z "$access_token" ]; then
        echo "Failed to retrieve access token using gcloud. Exiting..."
        exit 1
    fi
fi

bucket_sizes=()

# Iterate over each project ID provided
for project_id in "${projects[@]}"; do
    echo "Processing project: $project_id"

    # List all buckets in the project
    buckets=$(list_buckets "$project_id" "$access_token")

    # Check if the Monitoring API is enabled
    if is_monitoring_api_enabled "$project_id" "$access_token"; then
        echo "Monitoring API is enabled for project: $project_id"

       # Get the sizes of all buckets
        all_bucket_sizes=$(get_all_bucket_sizes "$project_id" "$access_token")

        # Iterate over each bucket and match its size
        for bucket_name in $buckets; do
            echo "Processing bucket: $bucket_name"

            size_bytes=$(echo "$all_bucket_sizes" | jq -r --arg bucket_name "$bucket_name" '. | select(.bucket_name == $bucket_name) | .size_bytes')
            if [ -n "$size_bytes" ]; then
                size_gb=$(bytes_to_gb $size_bytes)
                metadata=$(get_bucket_metadata "$bucket_name" "$access_token")
                region=$(echo "$metadata" | jq -r '.location')
                storage_class=$(echo "$metadata" | jq -r '.storageClass')
                size_tb=$(bytes_to_tb $size_bytes)
                bucket_sizes+=("{\"project\": \"$project_id\", \"bucket\": \"$bucket_name\", \"size_tb\": $size_tb, \"storage_class\": \"$storage_class\", \"region\": \"$region\"}")
            else
                echo "No size data found for bucket: $bucket_name"
            fi
        done
    else
        echo "Monitoring API is not enabled for project: $project_id. Falling back to gsutil."

        # Iterate over each bucket and calculate its size using gsutil
        for bucket_name in $buckets; do
            echo "Processing bucket: $bucket_name"

            # Get the size of the bucket using gsutil
            size_bytes=$(get_bucket_size_gsutil "$bucket_name" "$access_token")
            size_tb=$(bytes_to_tb $size_bytes)
            bucket_sizes+=("{\"project\": \"$project_id\", \"bucket\": \"$bucket_name\", \"size_tb\": $size_tb}")
        done
    fi
done

# Output the result in JSON format
echo "["$(IFS=,; echo "${bucket_sizes[*]}")"]" > ${CODEBUNDLE_TEMP_DIR}/bucket_report.json
cat ${CODEBUNDLE_TEMP_DIR}/bucket_report.json | jq 'sort_by(.size_tb) | reverse'
