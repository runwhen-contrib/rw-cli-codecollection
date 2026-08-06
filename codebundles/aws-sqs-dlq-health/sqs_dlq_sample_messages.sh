#!/usr/bin/env bash
# Receives a bounded sample of DLQ messages (short visibility), extracts diagnostics, returns visibility to 0.
# Writes JSON issues to dlq_sample_issues.json (jq).

set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/auth.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/sqs_dlq_common.sh"

auth

: "${AWS_REGION:?Must set AWS_REGION}"

OUTPUT_FILE="dlq_sample_issues.json"
MAX_SAMPLE="${MAX_DLQ_MESSAGES_TO_SAMPLE:-5}"
VIS_SECONDS="${DLQ_SAMPLE_VISIBILITY_SECONDS:-10}"
issues_json='[]'

echo "=== DLQ message sample (max ${MAX_SAMPLE} messages total per run, visibility ${VIS_SECONDS}s) ==="

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
    issues_json=$(echo "$issues_json" | jq \
        --arg title "No source queues for DLQ sampling" \
        --arg details "Provide SQS_QUEUE_URL / SQS_QUEUE_URLS or list-queues discovery." \
        --argjson severity 4 \
        --arg next_steps "Configure queue URLs or prefix discovery." \
        '. += [{
          "title": $title,
          "details": $details,
          "severity": $severity,
          "next_steps": $next_steps
        }]')
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 0
fi

declare -A SEEN_DLQ
declare -a DLQ_URLS=()

for src in "${SOURCE_URLS[@]}"; do
    [[ -z "$src" ]] && continue
    resolved=$(rw_sqs_resolve_dlq_url "$src" || true)
    [[ -z "$resolved" ]] && continue
    dlq_arn="${resolved%%|*}"
    dlq_url="${resolved##*|}"
    if [[ -n "${SEEN_DLQ[$dlq_arn]:-}" ]]; then
        continue
    fi
    SEEN_DLQ[$dlq_arn]=1
    DLQ_URLS+=("$dlq_url")
done

if [[ ${#DLQ_URLS[@]} -eq 0 ]]; then
    echo "No DLQs resolved from source queues (missing RedrivePolicy)."
    echo '[]' > "$OUTPUT_FILE"
    exit 0
fi

total_sampled=0
for dlq_url in "${DLQ_URLS[@]}"; do
    [[ "$total_sampled" -ge "$MAX_SAMPLE" ]] && break
    depth=$(rw_sqs_queue_depth "$dlq_url")
    if [[ ! "$depth" =~ ^[0-9]+$ ]] || [[ "$depth" -eq 0 ]]; then
        echo "DLQ ${dlq_url} empty; skipping receive."
        continue
    fi

    while [[ "$total_sampled" -lt "$MAX_SAMPLE" ]]; do
        batch=$((MAX_SAMPLE - total_sampled > 10 ? 10 : MAX_SAMPLE - total_sampled))
        resp=$(aws sqs receive-message \
            --queue-url "$dlq_url" \
            --max-number-of-messages "$batch" \
            --visibility-timeout "$VIS_SECONDS" \
            --attribute-names All \
            --message-attribute-names All \
            --output json 2>/dev/null || echo '{}')

        cnt=$(echo "$resp" | jq '.Messages | length // 0')
        if [[ "$cnt" -eq 0 ]]; then
            break
        fi

        while IFS= read -r msg; do
            [[ -z "$msg" ]] && continue
            mid=$(echo "$msg" | jq -r '.MessageId // empty')
            body=$(echo "$msg" | jq -r '.Body // ""' | head -c 4000)
            rh=$(echo "$msg" | jq -r '.ReceiptHandle // empty')
            attrs=$(echo "$msg" | jq -c '.Attributes // {}')
            mattrs=$(echo "$msg" | jq -c '.MessageAttributes // {}')

            if [[ -n "$rh" ]]; then
                aws sqs change-message-visibility --queue-url "$dlq_url" --receipt-handle "$rh" --visibility-timeout 0 --region "$AWS_REGION" >/dev/null 2>&1 || true
            fi

            total_sampled=$((total_sampled + 1))

            details_json=$(jq -n \
                --arg mid "$mid" \
                --arg body "$body" \
                --argjson attrs "$attrs" \
                --argjson mattrs "$mattrs" \
                '{messageId: $mid, bodySnippet: $body, attributes: $attrs, messageAttributes: $mattrs}')
            details_str=$(echo "$details_json" | jq -c .)

            issues_json=$(echo "$issues_json" | jq \
                --arg title "DLQ diagnostic sample for \`${dlq_url}\`" \
                --arg details "$details_str" \
                --argjson severity 3 \
                --arg next_steps "Review body for Lambda async failure fields, application errors, or poison payloads. Fix consumer logic; use redrive or delete after remediation. FIFO: avoid partial batch pitfalls if using partial batch responses." \
                '. += [{
                  "title": $title,
                  "details": $details,
                  "severity": $severity,
                  "next_steps": $next_steps
                }]')

            if [[ "$total_sampled" -ge "$MAX_SAMPLE" ]]; then
                break 3
            fi
        done < <(echo "$resp" | jq -c '.Messages[]? // empty')
    done
done

echo "$issues_json" > "$OUTPUT_FILE"
echo "Wrote ${OUTPUT_FILE}"
exit 0
