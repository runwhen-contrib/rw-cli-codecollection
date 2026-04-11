#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Snapshot CloudWatch metrics for primary queues and DLQs (~15 minute window).
# Writes: cloudwatch_queue_metrics_issues.json (informational only; often empty)
# -----------------------------------------------------------------------------

: "${AWS_REGION:?Must set AWS_REGION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=auth.sh
source "${SCRIPT_DIR}/auth.sh"

auth

OUTPUT_FILE="cloudwatch_queue_metrics_issues.json"
CONTEXT_FILE="sqs_investigation_context.json"
issues_json='[]'

if [[ ! -f "$CONTEXT_FILE" ]]; then
    echo '[]' > "$OUTPUT_FILE"
    echo "No $CONTEXT_FILE; skipping metrics."
    exit 0
fi

if date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    START_TS=$(date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
else
    START_TS=$(date -u -v-15M +%Y-%m-%dT%H:%M:%SZ)
fi
END_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

metrics_report='[]'

sqs_sum_metric() {
    local qname="$1"
    local metric="$2"
    aws cloudwatch get-metric-statistics \
        --region "$AWS_REGION" \
        --namespace AWS/SQS \
        --metric-name "$metric" \
        --dimensions Name=QueueName,Value="$qname" \
        --start-time "$START_TS" \
        --end-time "$END_TS" \
        --period 300 \
        --statistics Sum \
        --output json 2>/dev/null | jq '[.Datapoints[].Sum] | add // 0'
}

while IFS= read -r line; do
    primary_url=$(echo "$line" | jq -r '.primary_url')
    dlq_url=$(echo "$line" | jq -r '.dlq_url // empty')
    [[ -z "$primary_url" ]] && continue
    p_name=$(basename "$primary_url")

    ns=$(sqs_sum_metric "$p_name" NumberOfMessagesSent)
    nr=$(sqs_sum_metric "$p_name" NumberOfMessagesReceived)
    nd=$(sqs_sum_metric "$p_name" NumberOfMessagesDeleted)
    nyd=$(sqs_sum_metric "$p_name" ApproximateNumberOfMessagesDelayed)

    primary_metrics=$(jq -n \
        --argjson sent "$ns" \
        --argjson recv "$nr" \
        --argjson del "$nd" \
        --argjson delayed "$nyd" \
        '{NumberOfMessagesSent: $sent, NumberOfMessagesReceived: $recv, NumberOfMessagesDeleted: $del, ApproximateNumberOfMessagesDelayed: $delayed}')

    dlq_json=null
    if [[ -n "$dlq_url" ]]; then
        d_name=$(basename "$dlq_url")
        d_sent=$(sqs_sum_metric "$d_name" NumberOfMessagesSent)
        d_recv=$(sqs_sum_metric "$d_name" NumberOfMessagesReceived)
        d_vis=$(sqs_sum_metric "$d_name" ApproximateNumberOfMessagesVisible)
        d_del=$(sqs_sum_metric "$d_name" NumberOfMessagesDeleted)
        dlq_json=$(jq -n \
            --arg n "$d_name" \
            --argjson sent "$d_sent" \
            --argjson recv "$d_recv" \
            --argjson vis "$d_vis" \
            --argjson del "$d_del" \
            '{queue: $n, NumberOfMessagesSent: $sent, NumberOfMessagesReceived: $recv, ApproximateNumberOfMessagesVisible: $vis, NumberOfMessagesDeleted: $del}')
    fi

    row=$(jq -n \
        --arg p "$p_name" \
        --argjson pm "$primary_metrics" \
        --argjson d "$dlq_json" \
        '{primary_queue: $p, primary_metrics: $pm, dlq: $d}')
    metrics_report=$(echo "$metrics_report" | jq --argjson r "$row" '. + [$r]')
done < <(jq -c '.queues[]?' "$CONTEXT_FILE")

echo "$issues_json" > "$OUTPUT_FILE"
echo "CloudWatch metrics snapshot (last ~15m, Sum where applicable):"
echo "$metrics_report" | jq .
jq . "$OUTPUT_FILE"
