#!/usr/bin/env bash
set -euo pipefail

: "${OPENROUTER_API_KEY:?Must set OPENROUTER_API_KEY}"
: "${OPENROUTER_BUDGET_USD:=0}"
: "${OPENROUTER_API_BASE_URL:=https://openrouter.ai/api/v1}"

OUTPUT_FILE="budget_issues.json"
issues_json='[]'

get_with_status() {
  local path="$1"
  local tmp status body
  tmp=$(mktemp)
  status=$(curl -s -S --max-time 30 -o "$tmp" -w "%{http_code}" \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    "$OPENROUTER_API_BASE_URL$path" || true)
  body=$(cat "$tmp")
  rm -f "$tmp"
  printf '%s\n%s\n' "$status" "$body"
}

echo "Checking OpenRouter budget status..."

budget=$(echo "$OPENROUTER_BUDGET_USD" | jq -r '. // 0')
budget_disabled=$(echo "$budget == 0" | bc -l)

if [ "$budget_disabled" -eq 1 ]; then
  echo "Budget checking is disabled (budget=0). Skipping budget checks."
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

key_result=$(get_with_status "/key")
http_code=$(echo "$key_result" | sed -n '1p')
api_response=$(echo "$key_result" | sed -n '2,$p')

if [ "$http_code" != "200" ]; then
  err_msg=$(echo "$api_response" | jq -cr '.error.message // .message // "Unknown error"' 2>/dev/null || echo "Unknown error")
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot Reach OpenRouter API for Budget Check" \
    --arg details "API call to /key failed with HTTP $http_code: $err_msg" \
    --arg severity "4" \
    --arg next_steps "Verify API key validity and OpenRouter API availability" \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

if ! echo "$api_response" | jq -e '.data' >/dev/null 2>&1; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "OpenRouter API Key Invalid or Expired" \
    --arg details "The /key response did not include a valid data object." \
    --arg severity "4" \
    --arg next_steps "Generate a new API key at https://openrouter.ai/settings/keys and update OPENROUTER_API_KEY." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

is_management_key=$(echo "$api_response" | jq -r '.data.is_management_key // false')
usage_period=$(echo "$api_response" | jq -r '.data.usage_monthly // .data.usage // 0')
usage_total=$(echo "$api_response" | jq -r '.data.usage // 0')
limit_remaining=$(echo "$api_response" | jq -r '.data.limit_remaining // "null"')

if [ "$is_management_key" = "true" ]; then
  keys_result=$(get_with_status "/keys?include_disabled=true&offset=0&limit=100")
  keys_http_code=$(echo "$keys_result" | sed -n '1p')
  keys_response=$(echo "$keys_result" | sed -n '2,$p')

  if [ "$keys_http_code" = "200" ] && echo "$keys_response" | jq -e '.data' >/dev/null 2>&1; then
    usage_period=$(echo "$keys_response" | jq '[.data[]? | (.usage_monthly // .usage // 0)] | add // 0')
    usage_total=$(echo "$keys_response" | jq '[.data[]? | (.usage // 0)] | add // 0')
    limit_remaining=$(echo "$keys_response" | jq '[.data[]? | (.limit_remaining // 0)] | add // 0')
  fi
fi

echo "Account: period_usage=$usage_period, total_usage=$usage_total, remaining_limit=$limit_remaining, budget=$budget"

if [ "$(echo "$usage_period > $budget" | bc -l)" -eq 1 ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "OpenRouter Budget Exceeded" \
    --arg details "Current period usage of \$$usage_period exceeds configured budget of \$$budget. Total usage: \$$usage_total." \
    --arg severity "4" \
    --arg next_steps "Reduce spend or increase the budget. Consider limits at https://openrouter.ai/settings/limits." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
fi

if [ "$limit_remaining" != "null" ] && [ "$(echo "$limit_remaining >= 0" | bc -l)" -eq 1 ]; then
  limit_total=$(echo "$usage_period + $limit_remaining" | bc -l)
  if [ "$(echo "$limit_total > 0" | bc -l)" -eq 1 ]; then
    burn_rate=$(echo "scale=2; ($usage_period / $limit_total) * 100" | bc -l)
    if [ "$(echo "$burn_rate > 80" | bc -l)" -eq 1 ]; then
      issues_json=$(echo "$issues_json" | jq \
        --arg title "OpenRouter Budget Depletion Risk" \
        --arg details "Current period usage of \$$usage_period is ${burn_rate}% of available limit (usage + remaining = \$$limit_total)." \
        --arg severity "3" \
        --arg next_steps "Top up credits or adjust key/workspace limits before the reset period." \
        '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    fi
  fi
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Budget check completed. Results saved to $OUTPUT_FILE"