#!/bin/bash

SERVICE_ACCOUNT_KEY=$GOOGLE_APPLICATION_CREDENTIALS
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

# Function to get the sizes of all buckets using PromQL
get_bucket_read_ops() {
    local project_id=$1
    local token=$2

    local response=$(curl -s --header "Authorization: Bearer $token" \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data 'query=sum by (bucket_name)(rate(storage_googleapis_com:api_request_count{monitored_resource="gcs_bucket",method=~"Read.*|List.*|Get.*"}[30m]))' \
        "https://monitoring.googleapis.com/v1/projects/$project_id/location/global/prometheus/api/v1/query")

    echo $response | jq -r '.data.result[] | {bucket_name: .metric.bucket_name, ops: .value[1]}'
}

# Function to get the sizes of all buckets using PromQL
get_bucket_write_ops() {
    local project_id=$1
    local token=$2

    local response=$(curl -s --header "Authorization: Bearer $token" \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data 'query=sum by (bucket_name)(rate(storage_googleapis_com:api_request_count{monitored_resource="gcs_bucket",method=~"Write.*"}[30m]))' \
        "https://monitoring.googleapis.com/v1/projects/$project_id/location/global/prometheus/api/v1/query")

    echo $response | jq -r '.data.result[] | {bucket_name: .metric.bucket_name, ops: .value[1]}'
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

read_ops=()
write_ops=()

# Iterate over each project ID provided
for project_id in "${projects[@]}"; do
    echo "Processing project: $project_id"

    # List all buckets in the project
    buckets=$(list_buckets "$project_id" "$access_token")

        # Iterate over each bucket and match its size
    if is_monitoring_api_enabled "$project_id" "$access_token"; then
        echo "Monitoring API is enabled for project: $project_id"

        # Get the read/write ops of all buckets
        all_bucket_read_ops=$(get_bucket_read_ops "$project_id" "$access_token")
        all_bucket_write_ops=$(get_bucket_write_ops "$project_id" "$access_token")

        # Iterate over each bucket and match its size
        for bucket_name in $buckets; do
            echo "Processing bucket: $bucket_name"
            
            # Initialize operations to zero
            read_ops=0
            write_ops=0

            # Get the read/write ops for the current bucket
            read_ops=$(echo "$all_bucket_read_ops" | jq -r --arg bucket_name "$bucket_name" '. | select(.bucket_name == $bucket_name) | .ops // 0 | tonumber | round')
            write_ops=$(echo "$all_bucket_write_ops" | jq -r --arg bucket_name "$bucket_name" '. | select(.bucket_name == $bucket_name) | .ops // 0 | tonumber | round')


            # Calculate total operations and cost using jq for arithmetic
            total_ops=$(echo "$write_ops $read_ops" | jq -n '[inputs] | add')

            # Add results to output
            echo "Read Rate: $read_ops ops/s, Write Rate: $write_ops ops/s, Total rate: $total_ops ops/s"

            # Get region
            region=$(echo "$metadata" | jq -r '.location')

            # Add bucket operations to the list
            bucket_ops+=("{\"project\": \"$project_id\", \"bucket\": \"$bucket_name\", \"write_ops\": \"$write_ops\", \"read_ops\": \"$read_ops\", \"total_ops\": \"$total_ops\", \"region\": \"$region\"}")
        done
    else
        echo "Monitoring API is not enabled for project: $project_id"
    fi

done

# Output the result in JSON format
echo "["$(IFS=,; echo "${bucket_ops[*]}")"]" > $HOME/bucket_ops_report.json
cat $HOME/bucket_ops_report.json | jq 'sort_by(.total_ops) | reverse'
