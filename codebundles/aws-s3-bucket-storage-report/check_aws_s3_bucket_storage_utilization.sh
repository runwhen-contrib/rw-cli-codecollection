#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=auth.sh
source "${SCRIPT_DIR}/auth.sh"

# Variables
# THRESHOLD=85

# Fetch a list of bucket names
bucket_names=$(aws s3api list-buckets --query "Buckets[].Name" --output text)

# Iterate over the bucket names
for bucket_name in $bucket_names; do
    # Check AWS S3 Bucket Storage Utilization
    usage=$(aws s3 ls s3://$bucket_name --recursive --human-readable --summarize | grep "Total Size")
    count=$(aws s3 ls s3://$bucket_name --recursive | wc -l)
    echo "$bucket_name      object count: $count        usage: $usage"
done


