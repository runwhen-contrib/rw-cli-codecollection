#!/usr/bin/env bash
# Pulls CloudWatch metrics for source queues (age, sent, deleted) to distinguish backlog vs poison patterns.
# Writes JSON issues to sqs_source_metrics_issues.json when oldest-message age is elevated (jq).

set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/auth.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/sqs_dlq_common.sh"

auth

: "${AWS_REGION:?Must set AWS_REGION}"

OUTPUT_FILE="sqs_source_metrics_issues.json"
LOOKBACK="${CLOUDWATCH_LOG_LOOKBACK_MINUTES:-30}"
issues_json='[]'

START=$(date -u -d "${LOOKBACK} minutes ago" +%FT%TZ)
END=$(date -u +%FT%TZ)

echo "=== Source queue CloudWatch metrics (${START} to ${END}, region=${AWS_REGION}) ==="

SOURCE_URLS=()
if [[ -n "${SQS_QUEUE_URL:-}" || -n "${SQS_QUEUE_URLS:-}" ]]; then
    while IFS= read -r line; do
        [[ -n "$line" ]] && SOURCE_URLS+=("$line")
    done < <(rw_sqs_collect_source_urls)
else
    prefix="${SQS_QUEUE_NAME_PREFIX:-}"
    raw=$(aws sqs list-queues --region "$AWS_REGION" ${prefix:+--queue-name-prefix "$prefix"} --output json 2>/dev/null || echo '{}')
    while IFS= read -r line; do
        [[ -n "$line" ]] && SOURCE_URLS+=("$line")
    done < <(echo "$raw" | jq -r '.QueueUrls[]? // empty')
fi

if [[ ${#SOURCE_URLS[@]} -eq 0 ]]; then
    echo '[]' > "$OUTPUT_FILE"
    exit 0
fi

for src in "${SOURCE_URLS[@]}"; do
    [[ -z "$src" ]] && continue
    qname=$(rw_sqs_queue_name_from_url "$src")
    echo "--- Queue: ${qname}"

    for metric in ApproximateAgeOfOldestMessage NumberOfMessagesSent NumberOfMessagesDeleted; do
        stats=$(aws cloudwatch get-metric-statistics \
            --namespace AWS/SQS \
            --metric-name "$metric" \
            --dimensions Name=QueueName,Value="$qname" \
            --start-time "$START" \
            --end-time "$END" \
            --period 60 \
            --statistics Maximum Average \
            --region "$AWS_REGION" \
            --output json 2>/dev/null || echo '{}')
        echo "${metric}: $(echo "$stats" | jq -c '{Datapoints: .Datapoints}')"
    done

    age_stats=$(aws cloudwatch get-metric-statistics \
        --namespace AWS/SQS \
        --metric-name ApproximateAgeOfOldestMessage \
        --dimensions Name=QueueName,Value="$qname" \
        --start-time "$START" \
        --end-time "$END" \
        --period 60 \
        --statistics Maximum \
        --region "$AWS_REGION" \
        --output json 2>/dev/null || echo '{}')

    max_age=$(echo "$age_stats" | jq '[.Datapoints[]?.Maximum // empty] | max // 0')
    # max_age may be float
    if awk -v m="$max_age" 'BEGIN { exit !(m > 300) }'; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Elevated ApproximateAgeOfOldestMessage for source queue \`${qname}\`" \
            --arg details "Maximum ApproximateAgeOfOldestMessage in window ≈ ${max_age}s (threshold 300s). Review consumer throughput vs poison messages; compare with DLQ samples." \
            --argjson severity 4 \
            --arg next_steps "Scale or fix the consumer if backlog-driven; if age is high with low DLQ volume, investigate slow processing. Cross-check NumberOfMessagesSent vs NumberOfMessagesDeleted in the report output." \
            '. += [{
              "title": $title,
              "details": $details,
              "severity": $severity,
              "next_steps": $next_steps
            }]')
    fi
done

echo "$issues_json" > "$OUTPUT_FILE"
echo "Wrote ${OUTPUT_FILE}"
exit 0
