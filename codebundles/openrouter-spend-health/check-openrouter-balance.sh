#!/usr/bin/env bash
set -euo pipefail
set -x

: "${OPENROUTER_API_KEY:?Must set OPENROUTER_API_KEY}"
: "${OPENROUTER_MIN_BALANCE_USD:=10}"

OUTPUT_FILE="balance_issues.json"
issues_json='[]'

echo "Checking OpenRouter account balance..."

if ! api_response=$(curl -s --max-time 30 \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" \
  "https://openrouter.ai/api/v1/auth/key" 2>err.log); then
    err_msg=$(cat err.log)
    rm -f err.log
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Cannot Reach OpenRouter API" \
      --arg details "API call to /api/v1/auth/key failed: $err_msg" \
      --arg severity "4" \
      --arg next_steps "Verify network connectivity and OpenRouter API availability status" \
      '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 0
fi
rm -f err.log

credits=$(echo "$api_response" | jq -r '.credits // "0"')
usage=$(echo "$api_response" | jq -r '.usage // "0"')

echo "Account: credits=$credits, usage=$usage, min_threshold=$OPENROUTER_MIN_BALANCE_USD"

balance_threshold=$(echo "$OPENROUTER_MIN_BALANCE_USD" | jq -r '. // 10')

if [ "$(echo "$credits < $balance_threshold" | bc -l)" -eq 1 ]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "OpenRouter Account Balance Low" \
      --arg details "Current balance is \$$credits, which is below the minimum threshold of \$$balance_threshold. Total lifetime usage: \$$usage." \
      --arg severity "3" \
      --arg next_steps "Add funds to the OpenRouter account. Visit https://openrouter.ai/settings/credits to add credits." \
      '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
fi

api_key_label=$(echo "$api_response" | jq -r '.label // "unknown"')
if [ "$api_key_label" = "null" ] || [ "$api_key_label" = "" ]; then
    api_key_label="unknown"
fi

if [ "$(echo "$api_response" | jq -r '.credits')" = "null" ]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "OpenRouter API Key Invalid or Expired" \
      --arg details "The API key appears to be invalid or expired. API response did not contain valid credit information." \
      --arg severity "4" \
      --arg next_steps "Generate a new API key at https://openrouter.ai/settings/keys and update the openrouter_api_key secret." \
      '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Balance check completed. Results saved to $OUTPUT_FILE"