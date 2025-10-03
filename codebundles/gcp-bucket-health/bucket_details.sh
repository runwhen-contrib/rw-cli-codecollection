#!/bin/bash

# Function to extract timestamp from log line, fallback to current time
extract_log_timestamp() {
    local log_line="$1"
    local fallback_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    if [[ -z "$log_line" ]]; then
        echo "$fallback_timestamp"
        return
    fi
    
    # Try to extract common timestamp patterns
    # ISO 8601 format: 2024-01-15T10:30:45.123Z
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z?) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Standard log format: 2024-01-15 10:30:45
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        # Convert to ISO format
        local extracted_time="${BASH_REMATCH[1]}"
        local iso_time=$(date -d "$extracted_time" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # DD-MM-YYYY HH:MM:SS format
    if [[ "$log_line" =~ ([0-9]{2}-[0-9]{2}-[0-9]{4}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        local extracted_time="${BASH_REMATCH[1]}"
        # Convert DD-MM-YYYY to YYYY-MM-DD for date parsing
        local day=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f1)
        local month=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f2)
        local year=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f3)
        local time_part=$(echo "$extracted_time" | cut -d' ' -f2)
        local iso_time=$(date -d "$year-$month-$day $time_part" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # Fallback to current timestamp
    echo "$fallback_timestamp"
}

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


# Function to list buckets in a project
list_buckets() {
    local project_id=$1
    local token=$2
    local response=$(curl -s --header "Authorization: Bearer $token" \
        "https://storage.googleapis.com/storage/v1/b?project=$project_id")

    echo $response | jq -r '.items[].name'
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
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

    # Extract timestamp from log context


    log_timestamp=$(extract_log_timestamp "$0")


    echo "Error: PROJECT_IDS environment variable is not set or empty. (detected at $log_timestamp)"
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

# Iterate over each project ID provided
for project_id in "${projects[@]}"; do
    # List all buckets in the project
    buckets=$(list_buckets "$project_id" "$access_token")

    for bucket_name in $buckets; do
            metadata=$(get_bucket_metadata "$bucket_name" "$access_token")
            echo $metadata >> bucket_configuration.json
    done
done

cat bucket_configuration.json | jq .
