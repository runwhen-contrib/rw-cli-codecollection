#!/usr/bin/env bash
set -euo pipefail

# gcloud/gsutil are authenticated by RW.Core.Import Secret (Suite Initialization).
# No key handling here -- use the session.

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

get_bucket_read_ops() {
    local project_id=$1 token=$2
    curl -s --header "Authorization: Bearer $token" \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data 'query=sum by (bucket_name)(rate(storage_googleapis_com:api_request_count{monitored_resource="gcs_bucket",method=~"Read.*|List.*|Get.*"}[30m]))' \
        "https://monitoring.googleapis.com/v1/projects/$project_id/location/global/prometheus/api/v1/query" \
    | jq -r '.data.result[]? | {bucket_name: .metric.bucket_name, ops: .value[1]}'
}

get_bucket_write_ops() {
    local project_id=$1 token=$2
    curl -s --header "Authorization: Bearer $token" \
        --header "Content-Type: application/x-www-form-urlencoded" \
        --data 'query=sum by (bucket_name)(rate(storage_googleapis_com:api_request_count{monitored_resource="gcs_bucket",method=~"Write.*"}[30m]))' \
        "https://monitoring.googleapis.com/v1/projects/$project_id/location/global/prometheus/api/v1/query" \
    | jq -r '.data.result[]? | {bucket_name: .metric.bucket_name, ops: .value[1]}'
}

get_bucket_metadata() {
    gcloud storage buckets describe "gs://$1" --format=json 2>/dev/null
}

: "${PROJECT_IDS:?Must set PROJECT_IDS}"
IFS=',' read -r -a projects <<< "$PROJECT_IDS"

bucket_ops=()

for project_id in "${projects[@]}"; do
    echo "Processing project: $project_id"

    buckets=$(list_buckets "$project_id")

    if is_monitoring_api_enabled "$project_id"; then
        echo "Monitoring API is enabled for project: $project_id"

        access_token=$(fetch_access_token)
        all_bucket_read_ops=$(get_bucket_read_ops "$project_id" "$access_token")
        all_bucket_write_ops=$(get_bucket_write_ops "$project_id" "$access_token")

        for bucket_name in $buckets; do
            echo "Processing bucket: $bucket_name"

            read_ops=$(echo "$all_bucket_read_ops" | jq -r --arg bucket_name "$bucket_name" '. | select(.bucket_name == $bucket_name) | .ops // 0 | tonumber | round')
            write_ops=$(echo "$all_bucket_write_ops" | jq -r --arg bucket_name "$bucket_name" '. | select(.bucket_name == $bucket_name) | .ops // 0 | tonumber | round')
            read_ops=${read_ops:-0}
            write_ops=${write_ops:-0}

            total_ops=$(echo "$write_ops $read_ops" | jq -n '[inputs] | add')
            echo "Read Rate: $read_ops ops/s, Write Rate: $write_ops ops/s, Total rate: $total_ops ops/s"

            metadata=$(get_bucket_metadata "$bucket_name")
            region=$(echo "$metadata" | jq -r '.location // "unknown"')

            bucket_ops+=("{\"project\": \"$project_id\", \"bucket\": \"$bucket_name\", \"write_ops\": \"$write_ops\", \"read_ops\": \"$read_ops\", \"total_ops\": \"$total_ops\", \"region\": \"$region\"}")
        done
    else
        echo "Monitoring API is not enabled for project: $project_id"
    fi
done

if [ ${#bucket_ops[@]} -eq 0 ]; then
    echo "[]" > bucket_ops_report.json
else
    printf '%s\n' "${bucket_ops[@]}" | jq -s 'sort_by(.total_ops | tonumber) | reverse' > bucket_ops_report.json
fi
cat bucket_ops_report.json