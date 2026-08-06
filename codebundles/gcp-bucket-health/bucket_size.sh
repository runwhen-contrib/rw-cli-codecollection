#!/usr/bin/env bash
set -euo pipefail

# gcloud/gsutil are authenticated by RW.Core.Import Secret (Suite Initialization).
# No key handling here -- use the session.

bytes_to_tb() { awk "BEGIN {printf \"%.4f\", $1 / (1024^4)}"; }
bytes_to_gb() { awk "BEGIN {printf \"%.4f\", $1 / (1024^3)}"; }

# Thin token fetch for REST endpoints with no gcloud equivalent (PromQL).
# Uses the session established at import time.
fetch_access_token() {
    local token
    token=$(gcloud auth application-default print-access-token 2>/dev/null) || true
    if [ -z "${token:-}" ]; then
        token=$(gcloud auth print-access-token 2>/dev/null) || true
    fi
    if [ -z "${token:-}" ]; then
        echo "Failed to retrieve a GCP access token from the authenticated gcloud session." >&2
        return 1
    fi
    echo "$token"
}

is_monitoring_api_enabled() {
    local project_id=$1
    gcloud services list --enabled --project "$project_id" \
        --filter="name:monitoring.googleapis.com" --format="value(name)" 2>/dev/null \
        | grep -q "monitoring.googleapis.com"
}

list_buckets() {
    local project_id=$1
    gsutil ls -p "$project_id" 2>/dev/null | sed -e 's|gs://||' -e 's|/$||'
}

get_bucket_size_gsutil() {
    local size_bytes
    size_bytes=$(gsutil du -s "gs://$1" 2>/dev/null | awk '{print $1}') || true
    echo "${size_bytes:-0}"
}

get_all_bucket_sizes() {
    local project_id=$1 token=$2
    curl -s --header "Authorization: Bearer $token" \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data 'query=sum by (bucket_name) (avg_over_time(storage_googleapis_com:storage_total_bytes{monitored_resource="gcs_bucket"}[30m]))' \
        "https://monitoring.googleapis.com/v1/projects/$project_id/location/global/prometheus/api/v1/query" \
    | jq -r '.data.result[]? | {bucket_name: .metric.bucket_name, size_bytes: .value[1]}'
}

get_bucket_metadata() {
    gcloud storage buckets describe "gs://$1" --format=json 2>/dev/null
}

: "${PROJECT_IDS:?Must set PROJECT_IDS}"
IFS=',' read -r -a projects <<< "$PROJECT_IDS"

bucket_sizes=()

for project_id in "${projects[@]}"; do
    echo "Processing project: $project_id"

    buckets=$(list_buckets "$project_id")

    if is_monitoring_api_enabled "$project_id"; then
        echo "Monitoring API is enabled for project: $project_id"

        access_token=$(fetch_access_token)
        all_bucket_sizes=$(get_all_bucket_sizes "$project_id" "$access_token")

        for bucket_name in $buckets; do
            echo "Processing bucket: $bucket_name"

            size_bytes=$(echo "$all_bucket_sizes" | jq -r --arg bucket_name "$bucket_name" '. | select(.bucket_name == $bucket_name) | .size_bytes // empty')
            if [ -n "$size_bytes" ]; then
                size_gb=$(bytes_to_gb "$size_bytes")
                metadata=$(get_bucket_metadata "$bucket_name")
                region=$(echo "$metadata" | jq -r '.location // "unknown"')
                storage_class=$(echo "$metadata" | jq -r '.storageClass // "unknown"')
                size_tb=$(bytes_to_tb "$size_bytes")
                bucket_sizes+=("{\"project\": \"$project_id\", \"bucket\": \"$bucket_name\", \"size_tb\": $size_tb, \"storage_class\": \"$storage_class\", \"region\": \"$region\"}")
            else
                echo "No size data found for bucket: $bucket_name"
            fi
        done
    else
        echo "Monitoring API is not enabled for project: $project_id. Falling back to gsutil."

        for bucket_name in $buckets; do
            echo "Processing bucket: $bucket_name"
            size_bytes=$(get_bucket_size_gsutil "$bucket_name")
            size_tb=$(bytes_to_tb "$size_bytes")
            bucket_sizes+=("{\"project\": \"$project_id\", \"bucket\": \"$bucket_name\", \"size_tb\": $size_tb}")
        done
    fi
done

if [ ${#bucket_sizes[@]} -eq 0 ]; then
    echo "[]" > bucket_report.json
else
    printf '%s\n' "${bucket_sizes[@]}" | jq -s 'sort_by(.size_tb) | reverse' > bucket_report.json
fi
cat bucket_report.json