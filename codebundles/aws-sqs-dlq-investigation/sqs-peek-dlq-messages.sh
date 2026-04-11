#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Non-destructively samples messages from DLQs (short visibility timeout).
# Writes: peek_dlq_issues.json
# Env: AWS_REGION, MAX_DLQ_SAMPLE_MESSAGES (default 5), sqs_investigation_context.json input
# -----------------------------------------------------------------------------

: "${AWS_REGION:?Must set AWS_REGION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sqs-common.sh
source "${SCRIPT_DIR}/sqs-common.sh"
# shellcheck source=auth.sh
source "${SCRIPT_DIR}/auth.sh"

auth

OUTPUT_FILE="peek_dlq_issues.json"
CONTEXT_FILE="sqs_investigation_context.json"
MAX_MSG="${MAX_DLQ_SAMPLE_MESSAGES:-5}"
issues_json='[]'

if [[ ! -f "$CONTEXT_FILE" ]]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Missing investigation context" \
        --arg details "Run Check SQS Redrive Policy and DLQ Depth first, or ensure $CONTEXT_FILE exists." \
        --argjson severity 4 \
        --arg next_steps "Re-run the redrive/DLQ depth task before peeking messages." \
        '. += [{
          "title": $title,
          "details": $details,
          "severity": $severity,
          "next_steps": $next_steps
        }]')
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 0
fi

mapfile -t DLQ_URLS < <(jq -r '.queues[]? | select(.dlq_url != null and .dlq_url != "") | .dlq_url' "$CONTEXT_FILE" | sort -u)

if [[ ${#DLQ_URLS[@]} -eq 0 ]]; then
    echo "No DLQ URLs in context; nothing to peek."
    echo '[]' > "$OUTPUT_FILE"
    exit 0
fi

peek_summary='[]'

for dlq_url in "${DLQ_URLS[@]}"; do
    echo "Peeking DLQ: $dlq_url"
    recv=$(aws sqs receive-message \
        --region "$AWS_REGION" \
        --queue-url "$dlq_url" \
        --max-number-of-messages "$MAX_MSG" \
        --visibility-timeout 5 \
        --attribute-names All \
        --message-attribute-names All \
        --output json 2>/dev/null) || recv="{}"

    count=$(echo "$recv" | jq '[.Messages[]?] | length')
    msgs=$(echo "$recv" | jq '[.Messages[]? | {
      MessageId: .MessageId,
      BodySnippet: (.Body // "" | if length > 800 then .[0:800] + "..." else . end),
      Attributes: .Attributes,
      MessageAttributes: .MessageAttributes
    }]')

    peek_summary=$(echo "$peek_summary" | jq \
        --arg u "$dlq_url" \
        --argjson m "$msgs" \
        --argjson c "$count" \
        '. += [{ "dlq_url": $u, "sampled": $c, "messages": $m }]')

    if [[ "$count" -gt 0 ]]; then
        detail_line=$(echo "$peek_summary" | jq -c --arg u "$dlq_url" '.[] | select(.dlq_url==$u)')
        issues_json=$(echo "$issues_json" | jq \
            --arg title "DLQ message sample at queue" \
            --arg details "$detail_line" \
            --argjson severity 3 \
            --arg next_steps "Correlate body snippets with Lambda logs; fix downstream errors before redriving." \
            --arg u "$dlq_url" \
            '. += [{
              "title": ($title + " `" + $u + "`"),
              "details": $details,
              "severity": $severity,
              "next_steps": $next_steps
            }]')
    fi
done

echo "$issues_json" > "$OUTPUT_FILE"
echo "Peek summary:"
echo "$peek_summary" | jq .
jq . "$OUTPUT_FILE"
