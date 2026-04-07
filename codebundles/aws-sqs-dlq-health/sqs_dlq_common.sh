#!/usr/bin/env bash
# Shared helpers for aws-sqs-dlq-health (sourced by task scripts).

# Collect source queue URLs: explicit SQS_QUEUE_URL / SQS_QUEUE_URLS or list-queues with optional prefix.
# Prints one URL per line. Returns non-zero if list-queues fails when discovery is used.
rw_sqs_collect_source_urls() {
    local merged=()
    if [[ -n "${SQS_QUEUE_URL:-}" ]]; then
        merged+=("${SQS_QUEUE_URL}")
    fi
    if [[ -n "${SQS_QUEUE_URLS:-}" ]]; then
        local IFS_orig="$IFS"
        IFS=',' read -ra PARTS <<< "${SQS_QUEUE_URLS}"
        IFS="$IFS_orig"
        for p in "${PARTS[@]}"; do
            p=$(echo "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -z "$p" ]] && continue
            merged+=("$p")
        done
    fi
    if [[ ${#merged[@]} -gt 0 ]]; then
        printf '%s\n' "${merged[@]}"
        return 0
    fi
    local prefix="${SQS_QUEUE_NAME_PREFIX:-}"
    local raw
    if ! raw=$(aws sqs list-queues --region "$AWS_REGION" ${prefix:+--queue-name-prefix "$prefix"} --output json 2>/dev/null); then
        return 1
    fi
    echo "$raw" | jq -r '.QueueUrls[]? // empty'
}

# From a source queue URL, print "dlq_arn|dlq_url" or nothing. Uses RedrivePolicy on the source queue.
rw_sqs_resolve_dlq_url() {
    local qurl="$1"
    local attrs
    attrs=$(aws sqs get-queue-attributes --queue-url "$qurl" --attribute-names RedrivePolicy --output json 2>/dev/null || echo '{}')
    local policy
    policy=$(echo "$attrs" | jq -r '.Attributes.RedrivePolicy // empty')
    [[ -z "$policy" || "$policy" == "null" ]] && return 1
    local dlq_arn
    dlq_arn=$(echo "$policy" | jq -r '.deadLetterTargetArn // empty')
    [[ -z "$dlq_arn" ]] && return 1
    local dlq_name
    dlq_name=$(echo "$dlq_arn" | awk -F: '{print $NF}')
    local dlq_url
    dlq_url=$(aws sqs get-queue-url --queue-name "$dlq_name" --region "$AWS_REGION" --output json 2>/dev/null | jq -r '.QueueUrl // empty')
    [[ -z "$dlq_url" ]] && return 1
    printf '%s|%s\n' "$dlq_arn" "$dlq_url"
}

# Approximate message count for a queue URL.
rw_sqs_queue_depth() {
    local qurl="$1"
    aws sqs get-queue-attributes --queue-url "$qurl" --attribute-names ApproximateNumberOfMessages --output json 2>/dev/null \
        | jq -r '.Attributes.ApproximateNumberOfMessages // "0"'
}

# Queue name segment from an SQS HTTPS URL (last path component, URL-decoded for .fifo).
rw_sqs_queue_name_from_url() {
    local qurl="$1"
    echo "$qurl" | awk -F/ '{print $NF}' | sed 's/%20/ /g'
}
