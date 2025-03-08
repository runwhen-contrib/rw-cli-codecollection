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

# Iterate over each project ID provided
for project_id in "${projects[@]}"; do
    # List all buckets in the project
    buckets=$(list_buckets "$project_id" "$access_token")

    for bucket_name in $buckets; do
            metadata=$(get_bucket_metadata "$bucket_name" "$access_token")
            echo $metadata >> ${CODEBUNDLE_TEMP_DIR}/bucket_configuration.json
    done
done

cat ${CODEBUNDLE_TEMP_DIR}/bucket_configuration.json | jq .
