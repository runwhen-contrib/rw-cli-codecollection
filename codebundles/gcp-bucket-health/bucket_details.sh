#!/usr/bin/env bash
set -euo pipefail

# gcloud/gsutil are authenticated by RW.Core.Import Secret (Suite Initialization).
# No key handling here -- use the session.

list_buckets() {
    local project_id=$1
    gsutil ls -p "$project_id" 2>/dev/null | sed -e 's|gs://||' -e 's|/$||'
}

get_bucket_metadata() {
    gcloud storage buckets describe "gs://$1" --format=json 2>/dev/null
}

: "${PROJECT_IDS:?Must set PROJECT_IDS}"
IFS=',' read -r -a projects <<< "$PROJECT_IDS"

> bucket_configuration.json

for project_id in "${projects[@]}"; do
    echo "Processing project: $project_id"
    buckets=$(list_buckets "$project_id")

    for bucket_name in $buckets; do
        metadata=$(get_bucket_metadata "$bucket_name")
        if [ -n "$metadata" ]; then
            echo "$metadata" >> bucket_configuration.json
        fi
    done
done

if [ -s bucket_configuration.json ]; then
    jq -s . bucket_configuration.json
else
    echo "[]"
fi