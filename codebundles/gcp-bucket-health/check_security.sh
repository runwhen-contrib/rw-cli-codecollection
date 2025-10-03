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

ACCESS_TOKEN=$(gcloud auth application-default print-access-token)
ISSUES=()

# Check if PROJECT_IDS is set
if [ -z "$PROJECT_IDS" ]; then
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

  # Extract timestamp from log context


  log_timestamp=$(extract_log_timestamp "$0")


  echo "Error: PROJECT_IDS is not set. Please set PROJECT_IDS to a comma-separated list of project IDs. (detected at $log_timestamp)"
  exit 1
fi

# Function to check bucket settings
check_bucket_settings() {
  local BUCKET=$1
  echo "Checking settings for bucket: $BUCKET"
  local RESPONSE=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://storage.googleapis.com/storage/v1/b/$BUCKET?fields=iamConfiguration,acl,encryption")

  local HTTP_STATUS=$(echo $RESPONSE | jq -r '.error.code // 200')
  if [ "$HTTP_STATUS" -ne 200 ]; then
    local MESSAGE=$(echo $RESPONSE | jq -r '.error.message')
    echo "Error fetching settings for bucket $BUCKET: $MESSAGE"
    return
  fi

  local IS_PUBLIC=false

  # Check public access
  local PUBLIC_ACCESS=$(echo $RESPONSE | jq -r '.iamConfiguration.bucketPolicyOnly.enabled // false')
  if [ "$PUBLIC_ACCESS" == "true" ]; then
    echo "Bucket $BUCKET has bucketPolicyOnly enabled."

    # Fetch IAM policy to check for public access
    local IAM_RESPONSE=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
      "https://storage.googleapis.com/storage/v1/b/$BUCKET/iam")

    local IAM_HTTP_STATUS=$(echo $IAM_RESPONSE | jq -r '.error.code // 200')
    if [ "$IAM_HTTP_STATUS" -ne 200 ]; then
      local IAM_MESSAGE=$(echo $IAM_RESPONSE | jq -r '.error.message')
      echo "Error fetching IAM policies for bucket $BUCKET: $IAM_MESSAGE"
    else
      local PUBLIC_IAM=$(echo $IAM_RESPONSE | jq '.bindings[]? | select(.members[]? == "allUsers" or .members[]? == "allAuthenticatedUsers")')
      if [ -n "$PUBLIC_IAM" ]; then
        echo "Bucket $BUCKET is publicly accessible via IAM policy!"
        IS_PUBLIC=true
      else
        echo "Bucket $BUCKET is not publicly accessible."
      fi
    fi
  else
    local PUBLIC_ACCESS_ACL=$(echo $RESPONSE | jq -r '.acl[]? | select(.entity == "allUsers" or .entity == "allAuthenticatedUsers")')
    if [ -n "$PUBLIC_ACCESS_ACL" ]; then
      echo "Bucket $BUCKET is publicly accessible via ACL!"
      IS_PUBLIC=true
    else
      echo "Bucket $BUCKET is not publicly accessible."
    fi
  fi

  if [ "$IS_PUBLIC" == true ]; then
    ISSUES+=("{\"bucket\": \"$BUCKET\", \"project\": \"$PROJECT_ID\", \"issue_type\": \"public_access\", \"issue_details\": \"public access is enabled\"}")
  fi

  # Check encryption settings
  local ENCRYPTION_KEY=$(echo $RESPONSE | jq -r '.encryption.defaultKmsKeyName // "Google-managed keys"')
  if [ "$ENCRYPTION_KEY" == "Google-managed keys" ]; then
    echo "Bucket $BUCKET is encrypted with Google-managed keys."
  else
    echo "Bucket $BUCKET is encrypted with customer-managed keys: $ENCRYPTION_KEY"
  fi
}

# Function to process each project
process_project() {
  local PROJECT_ID=$1
  echo "Processing project: $PROJECT_ID"
  
  # Get list of all buckets in the project
  local RESPONSE=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" \
    "https://storage.googleapis.com/storage/v1/b?project=$PROJECT_ID")

  local HTTP_STATUS=$(echo $RESPONSE | jq -r '.error.code // 200')
  if [ "$HTTP_STATUS" -ne 200 ]; then
    local MESSAGE=$(echo $RESPONSE | jq -r '.error.message')
    echo "Error fetching buckets for project $PROJECT_ID: $MESSAGE"
    return
  fi

  local BUCKETS=$(echo $RESPONSE | jq -r '.items[].name')

  # Iterate over each bucket and perform checks
  for BUCKET in $BUCKETS; do
    echo "Checking bucket: $BUCKET"
    check_bucket_settings "$BUCKET"
    echo "-----------------------------"
  done
}


# Convert PROJECT_IDS to an array
IFS=',' read -r -a PROJECT_IDS_ARRAY <<< "$PROJECT_IDS"

# Iterate over each project and process it
for PROJECT_ID in "${PROJECT_IDS_ARRAY[@]}"; do
  process_project $PROJECT_ID
done

# Output the security issues
echo "Security Issues:"
if [ ${#ISSUES[@]} -eq 0 ]; then
  echo "No security issues found."
  # Add empty json list to file so that json loads doesn't fail.
  echo "[{}]" > bucket_security_issues.json
else
  echo "${ISSUES[@]}" | jq -s . > bucket_security_issues.json
  cat bucket_security_issues.json
fi
