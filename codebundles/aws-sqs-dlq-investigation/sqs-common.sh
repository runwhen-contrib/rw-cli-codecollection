#!/usr/bin/env bash
# Shared helpers for SQS DLQ investigation scripts.
# shellcheck disable=SC1091

sqs_arn_to_name() {
    local arn="$1"
    echo "$arn" | awk -F: '{print $NF}'
}

# Resolve primary queue URLs from SQS_QUEUE_URLS or list-queues + RESOURCES filter.
sqs_resolve_primary_urls() {
    local urls=()
    if [[ -n "${SQS_QUEUE_URLS:-}" ]]; then
        IFS=',' read -ra raw <<< "${SQS_QUEUE_URLS}"
        for u in "${raw[@]}"; do
            u=$(echo "$u" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -n "$u" ]] && urls+=("$u")
        done
    else
        local queues_json
        if ! queues_json=$(aws sqs list-queues --region "$AWS_REGION" --output json 2>/dev/null); then
            echo "[]"
            return 1
        fi
        local filter="${RESOURCES:-All}"
        while IFS= read -r url; do
            [[ -z "$url" ]] && continue
            local qname
            qname=$(basename "$url")
            if [[ "$filter" == "All" || "$filter" == "" ]]; then
                urls+=("$url")
            elif [[ "$qname" == *"$filter"* ]]; then
                urls+=("$url")
            fi
        done < <(echo "$queues_json" | jq -r '.QueueUrls[]? // empty')
    fi
    printf '%s\n' "${urls[@]}"
}

sqs_get_queue_arn() {
    local queue_url="$1"
    aws sqs get-queue-attributes \
        --region "$AWS_REGION" \
        --queue-url "$queue_url" \
        --attribute-names QueueArn \
        --output json 2>/dev/null | jq -r '.Attributes.QueueArn // empty'
}
