#!/usr/bin/env bash

# gcloud/gsutil are authenticated by RW.Core.Import Secret (Suite Initialization).
# No key handling here -- use the session.

: "${PROJECT_IDS:?Must set PROJECT_IDS}"
ISSUES=()

check_bucket_settings() {
  local BUCKET=$1
  echo "Checking settings for bucket: $BUCKET"

  local desc
  if ! desc=$(gcloud storage buckets describe "gs://$BUCKET" --format=json 2>/dev/null); then
    echo "Error fetching settings for bucket $BUCKET"
    return
  fi

  local IS_PUBLIC=false

  # Uniform bucket-level access -> IAM is the only access path
  local uniform
  uniform=$(echo "$desc" | jq -r '.iamConfiguration.bucketPolicyOnly.enabled // .iamConfiguration.uniformBucketLevelAccess.enabled // false')

  if [ "$uniform" = "true" ]; then
    echo "Bucket $BUCKET has uniform bucket-level access enabled."
    local iam public_iam
    iam=$(gcloud storage buckets get-iam-policy "gs://$BUCKET" --format=json 2>/dev/null || echo '{}')
    public_iam=$(echo "$iam" | jq '[.bindings[]? | select(.members[]? == "allUsers" or .members[]? == "allAuthenticatedUsers")]')
    if [ "$(echo "$public_iam" | jq length)" -gt 0 ]; then
      echo "Bucket $BUCKET is publicly accessible via IAM policy!"
      IS_PUBLIC=true
    else
      echo "Bucket $BUCKET is not publicly accessible."
    fi
  else
    local acl public_acl
    acl=$(gsutil acl get "gs://$BUCKET" 2>/dev/null || echo '[]')
    public_acl=$(echo "$acl" | jq '[.[]? | select(.entity == "allUsers" or .entity == "allAuthenticatedUsers")]')
    if [ "$(echo "$public_acl" | jq length)" -gt 0 ]; then
      echo "Bucket $BUCKET is publicly accessible via ACL!"
      IS_PUBLIC=true
    else
      echo "Bucket $BUCKET is not publicly accessible."
    fi
  fi

  if [ "$IS_PUBLIC" = true ]; then
    ISSUES+=("{\"bucket\": \"$BUCKET\", \"project\": \"$PROJECT_ID\", \"issue_type\": \"public_access\", \"issue_details\": \"public access is enabled\"}")
  fi

  # Encryption settings
  local enc
  enc=$(echo "$desc" | jq -r '.encryption.defaultKmsKeyName // "Google-managed keys"')
  if [ "$enc" = "Google-managed keys" ]; then
    echo "Bucket $BUCKET is encrypted with Google-managed keys."
  else
    echo "Bucket $BUCKET is encrypted with customer-managed keys: $enc"
  fi
}

process_project() {
  local PROJECT_ID=$1
  echo "Processing project: $PROJECT_ID"

  local buckets
  buckets=$(gsutil ls -p "$PROJECT_ID" 2>/dev/null | sed -e 's|gs://||' -e 's|/$||')

  for BUCKET in $buckets; do
    echo "Checking bucket: $BUCKET"
    check_bucket_settings "$BUCKET"
    echo "-----------------------------"
  done
}

IFS=',' read -r -a PROJECT_IDS_ARRAY <<< "$PROJECT_IDS"

for PROJECT_ID in "${PROJECT_IDS_ARRAY[@]}"; do
  process_project "$PROJECT_ID"
done

echo "Security Issues:"
if [ ${#ISSUES[@]} -eq 0 ]; then
  echo "No security issues found."
  echo "[]" > bucket_security_issues.json
else
  printf '%s\n' "${ISSUES[@]}" | jq -s . > bucket_security_issues.json
  cat bucket_security_issues.json
fi