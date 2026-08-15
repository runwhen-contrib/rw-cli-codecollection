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
  workspaces_result=$(get_with_status "/workspaces?offset=0&limit=100")
  workspaces_http_code=$(echo "$workspaces_result" | sed -n '1p')
  workspaces_response=$(echo "$workspaces_result" | sed -n '2,$p')

  all_keys='[]'
  keys_available=0

  if [ "$workspaces_http_code" = "200" ] && echo "$workspaces_response" | jq -e '.data' >/dev/null 2>&1; then
    while IFS= read -r ws_id; do
      [ -z "$ws_id" ] && continue
      ws_keys_result=$(get_with_status "/keys?include_disabled=true&workspace_id=$ws_id&offset=0&limit=100")
      ws_keys_http_code=$(echo "$ws_keys_result" | sed -n '1p')
      ws_keys_response=$(echo "$ws_keys_result" | sed -n '2,$p')

      if [ "$ws_keys_http_code" = "200" ] && echo "$ws_keys_response" | jq -e '.data' >/dev/null 2>&1; then
        ws_batch=$(echo "$ws_keys_response" | jq '.data // []')
        all_keys=$(echo "$all_keys" | jq --argjson batch "$ws_batch" '. + $batch')
        keys_available=1
      fi
    done < <(echo "$workspaces_response" | jq -r '.data[]?.id')
  fi

  if [ "$keys_available" -eq 0 ]; then
    keys_result=$(get_with_status "/keys?include_disabled=true&offset=0&limit=100")
    keys_http_code=$(echo "$keys_result" | sed -n '1p')
    keys_response=$(echo "$keys_result" | sed -n '2,$p')
    if [ "$keys_http_code" = "200" ] && echo "$keys_response" | jq -e '.data' >/dev/null 2>&1; then
      all_keys=$(echo "$keys_response" | jq '.data // []')
      keys_available=1
    fi
  fi

  if [ "$keys_available" -eq 1 ]; then
    usage_period=$(echo "$all_keys" | jq '[.[]? | (.usage_monthly // .usage // 0)] | add // 0')
    usage_total=$(echo "$all_keys" | jq '[.[]? | (.usage // 0)] | add // 0')
    limit_remaining=$(echo "$all_keys" | jq '[.[]? | (.limit_remaining // 0)] | add // 0')
  fi
fi

echo "Account: period_usage=$usage_period, total_usage=$usage_total, remaining_limit=$limit_remaining, budget=$budget"

budget_snapshot=$(jq -n \
  --arg usage_period "$usage_period" \
  --arg usage_total "$usage_total" \
  --arg limit_remaining "$limit_remaining" \
  --arg budget "$budget" \
  --arg is_management_key "$is_management_key" \
  '{
    is_management_key: ($is_management_key == "true"),
    usage_period: ($usage_period | tonumber? // null),
    usage_total: ($usage_total | tonumber? // null),
    limit_remaining: ($limit_remaining | tonumber? // null),
    budget: ($budget | tonumber? // null)
  }')

echo "=== REPORT: BUDGET SNAPSHOT (JSON) ==="
echo "$budget_snapshot" | jq '.'

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