#!/usr/bin/env bash
set -euo pipefail

: "${OPENROUTER_API_KEY:?Must set OPENROUTER_API_KEY}"
: "${OPENROUTER_MIN_BALANCE_USD:=10}"
: "${OPENROUTER_API_BASE_URL:=https://openrouter.ai/api/v1}"

OUTPUT_FILE="balance_issues.json"
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

echo "Checking OpenRouter account balance..."

key_result=$(get_with_status "/key")
http_code=$(echo "$key_result" | sed -n '1p')
api_response=$(echo "$key_result" | sed -n '2,$p')

if [ "$http_code" != "200" ]; then
  err_msg=$(echo "$api_response" | jq -cr '.error.message // .message // "Unknown error"' 2>/dev/null || echo "Unknown error")
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot Reach OpenRouter API" \
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
credits=$(echo "$api_response" | jq -r '.data.limit_remaining // "null"')
usage=$(echo "$api_response" | jq -r '.data.usage // 0')
balance_threshold=$(echo "$OPENROUTER_MIN_BALANCE_USD" | jq -r '. // 10')
BALANCE_UNKNOWN=0

if [ "$is_management_key" = "true" ]; then
  keys_result=$(get_with_status "/keys?include_disabled=true&offset=0&limit=100")
  keys_http_code=$(echo "$keys_result" | sed -n '1p')
  keys_response=$(echo "$keys_result" | sed -n '2,$p')

  if [ "$keys_http_code" = "200" ] && echo "$keys_response" | jq -e '.data' >/dev/null 2>&1; then
    credits=$(echo "$keys_response" | jq '[.data[]? | (.limit_remaining // 0)] | add // 0')
    usage=$(echo "$keys_response" | jq '[.data[]? | (.usage // 0)] | add // 0')
    inactive_keys=$(echo "$keys_response" | jq '[.data[]? | select((.disabled // false) == true)] | length')
    key_count=$(echo "$keys_response" | jq '(.data // []) | length')
    echo "Management key detected ($key_count keys, inactive=$inactive_keys). Aggregated credits=$credits, usage=$usage"

    if [ "$inactive_keys" -gt 0 ]; then
      issues_json=$(echo "$issues_json" | jq \
        --arg title "Disabled OpenRouter API Keys Detected" \
        --arg details "Management key lists $inactive_keys disabled child API keys. Review https://openrouter.ai/settings/keys." \
        --arg severity "2" \
        --arg next_steps "Remove stale credentials or re-enable keys if they are still needed." \
        '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    fi
  else
    BALANCE_UNKNOWN=1
  fi

  workspaces_result=$(get_with_status "/workspaces?offset=0&limit=100")
  workspaces_http_code=$(echo "$workspaces_result" | sed -n '1p')
  workspaces_response=$(echo "$workspaces_result" | sed -n '2,$p')
  if [ "$workspaces_http_code" = "200" ] && echo "$workspaces_response" | jq -e '.data' >/dev/null 2>&1; then
    workspace_count=$(echo "$workspaces_response" | jq '(.data // []) | length')
    echo "Workspace count: $workspace_count"
    if [ "$workspace_count" -eq 0 ]; then
      issues_json=$(echo "$issues_json" | jq \
        --arg title "No OpenRouter Workspaces Found" \
        --arg details "The management key can authenticate, but /workspaces returned zero entries." \
        --arg severity "2" \
        --arg next_steps "Verify organization/workspace setup in https://openrouter.ai/settings." \
        '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    fi
  fi
fi

# Optional management-level credit totals (informational only)
if [ "$is_management_key" = "true" ]; then
  credits_result=$(get_with_status "/credits")
  credits_http_code=$(echo "$credits_result" | sed -n '1p')
  credits_response=$(echo "$credits_result" | sed -n '2,$p')
  if [ "$credits_http_code" = "200" ] && echo "$credits_response" | jq -e '.data' >/dev/null 2>&1; then
    total_credits=$(echo "$credits_response" | jq -r '.data.total_credits // 0')
    total_usage=$(echo "$credits_response" | jq -r '.data.total_usage // 0')
    remaining_total=$(echo "$total_credits - $total_usage" | bc -l)
    echo "Workspace/account credits summary: total_credits=$total_credits total_usage=$total_usage remaining=$remaining_total"
  fi
fi

echo "Account: credits=$credits, usage=$usage, min_threshold=$OPENROUTER_MIN_BALANCE_USD"

if [ "$BALANCE_UNKNOWN" -eq 1 ] || [ "$credits" = "null" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "OpenRouter Remaining Credits Not Reported" \
    --arg details "The authenticated key does not expose limit_remaining. Check key/workspace limits in https://openrouter.ai/settings/keys and billing in https://openrouter.ai/settings/credits." \
    --arg severity "2" \
    --arg next_steps "Set key or workspace limits if you need API-visible remaining balance for automation." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
elif [ "$(echo "$credits < $balance_threshold" | bc -l)" -eq 1 ]; then
  context="Current remaining limit is \$$credits, which is below the minimum threshold of \$$balance_threshold. Total usage: \$$usage."
  if [ "$is_management_key" = "true" ]; then
    context="Aggregated remaining limit across API keys is \$$credits, below the minimum threshold of \$$balance_threshold. Aggregated usage: \$$usage."
  fi
  issues_json=$(echo "$issues_json" | jq \
    --arg title "OpenRouter Account Balance Low" \
    --arg details "$context" \
    --arg severity "3" \
    --arg next_steps "Add funds or raise key/workspace limits. Visit https://openrouter.ai/settings/credits and https://openrouter.ai/settings/keys." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
fi

issues_json=$(echo "$issues_json" | jq 'sort_by(.severity)')

echo "$issues_json" > "$OUTPUT_FILE"
echo "Balance check completed. Results saved to $OUTPUT_FILE"