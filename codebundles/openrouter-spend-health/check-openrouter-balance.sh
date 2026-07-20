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

keys_response='{"data":[]}'
workspaces_response='{"data":[]}'
keys_available=0
workspaces_available=0

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
ACCOUNT_BALANCE_USD="null"
ACCOUNT_BALANCE_SOURCE="key_limit_remaining"

if [ "$is_management_key" = "true" ]; then
  workspaces_result=$(get_with_status "/workspaces?offset=0&limit=100")
  workspaces_http_code=$(echo "$workspaces_result" | sed -n '1p')
  workspaces_response=$(echo "$workspaces_result" | sed -n '2,$p')

  if [ "$workspaces_http_code" = "200" ] && echo "$workspaces_response" | jq -e '.data' >/dev/null 2>&1; then
    workspaces_available=1
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

    all_keys='[]'
    while IFS= read -r ws_id; do
      [ -z "$ws_id" ] && continue
      ws_keys_result=$(get_with_status "/keys?include_disabled=true&workspace_id=$ws_id&offset=0&limit=100")
      ws_keys_http_code=$(echo "$ws_keys_result" | sed -n '1p')
      ws_keys_response=$(echo "$ws_keys_result" | sed -n '2,$p')

      if [ "$ws_keys_http_code" = "200" ] && echo "$ws_keys_response" | jq -e '.data' >/dev/null 2>&1; then
        ws_batch=$(echo "$ws_keys_response" | jq '.data // []')
        all_keys=$(echo "$all_keys" | jq --argjson batch "$ws_batch" '. + $batch')
      fi
    done < <(echo "$workspaces_response" | jq -r '.data[]?.id')

    keys_response=$(jq -n --argjson data "$all_keys" '{data: $data}')
    keys_available=1
  fi

  # Fallback: if workspace-scoped key listing failed, try default /keys listing.
  if [ "$keys_available" -eq 0 ]; then
    keys_result=$(get_with_status "/keys?include_disabled=true&offset=0&limit=100")
    keys_http_code=$(echo "$keys_result" | sed -n '1p')
    keys_response=$(echo "$keys_result" | sed -n '2,$p')
    if [ "$keys_http_code" = "200" ] && echo "$keys_response" | jq -e '.data' >/dev/null 2>&1; then
      keys_available=1
    fi
  fi

  if [ "$keys_available" -eq 1 ]; then
    credits=$(echo "$keys_response" | jq '[.data[]? | (.limit_remaining // 0)] | add // 0')
    usage=$(echo "$keys_response" | jq '[.data[]? | (.usage // 0)] | add // 0')
    inactive_keys=$(echo "$keys_response" | jq '[.data[]? | select((.disabled // false) == true)] | length')
    key_count=$(echo "$keys_response" | jq '(.data // []) | length')
    unlimited_count=$(echo "$keys_response" | jq '[.data[]? | select(.limit == null)] | length')
    echo "Management key detected ($key_count keys, inactive=$inactive_keys, unlimited=$unlimited_count). Aggregated credits=$credits, usage=$usage"

    if [ "$inactive_keys" -gt 0 ]; then
      issues_json=$(echo "$issues_json" | jq \
        --arg title "Disabled OpenRouter API Keys Detected" \
        --arg details "Management key lists $inactive_keys disabled child API keys. Review https://openrouter.ai/settings/keys." \
        --arg severity "2" \
        --arg next_steps "Remove stale credentials or re-enable keys if they are still needed." \
        '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    fi

    if [ "$unlimited_count" -gt 0 ]; then
      while IFS= read -r key_meta; do
        [ -z "$key_meta" ] && continue
        key_name=$(echo "$key_meta" | jq -r '.name // .label // "(unnamed key)"')
        key_hash=$(echo "$key_meta" | jq -r '.hash // "unknown-hash"')
        key_disabled=$(echo "$key_meta" | jq -r '.disabled // false')
        issues_json=$(echo "$issues_json" | jq \
          --arg title "OpenRouter API Key Missing Spend Limit: $key_name" \
          --arg details "API key '$key_name' (hash: $key_hash, disabled=$key_disabled) has no limit configured (limit=null)." \
          --arg severity "4" \
          --arg next_steps "Set a per-key spending limit in https://openrouter.ai/settings/keys to enforce spend guardrails." \
          '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
      done < <(echo "$keys_response" | jq -c '.data[]? | select(.limit == null)')

      issues_json=$(echo "$issues_json" | jq \
        --arg title "OpenRouter Keys Without Limits Detected" \
        --arg details "$unlimited_count API key(s) have no spending limit configured (limit=null)." \
        --arg severity "4" \
        --arg next_steps "Add limits for all keys to prevent unbounded spend." \
        '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    fi
  else
    BALANCE_UNKNOWN=1
  fi
fi

# Management-level credit totals (/credits): this is the true account-level remaining balance.
if [ "$is_management_key" = "true" ]; then
  credits_result=$(get_with_status "/credits")
  credits_http_code=$(echo "$credits_result" | sed -n '1p')
  credits_response=$(echo "$credits_result" | sed -n '2,$p')
  if [ "$credits_http_code" = "200" ] && echo "$credits_response" | jq -e '.data' >/dev/null 2>&1; then
    total_credits=$(echo "$credits_response" | jq -r '.data.total_credits // 0')
    total_usage=$(echo "$credits_response" | jq -r '.data.total_usage // 0')
    remaining_total=$(echo "$total_credits - $total_usage" | bc -l)
    ACCOUNT_BALANCE_USD="$remaining_total"
    ACCOUNT_BALANCE_SOURCE="credits_endpoint"
    echo "Workspace/account credits summary: total_credits=$total_credits total_usage=$total_usage remaining=$remaining_total"
  fi
fi

if [ "$ACCOUNT_BALANCE_USD" = "null" ]; then
  ACCOUNT_BALANCE_USD="$credits"
fi

echo "Account: key_limit_remaining=$credits, usage=$usage, account_remaining=$ACCOUNT_BALANCE_USD, balance_source=$ACCOUNT_BALANCE_SOURCE, min_threshold=$OPENROUTER_MIN_BALANCE_USD"

if [ "$is_management_key" = "true" ] && [ "$keys_available" -eq 1 ]; then
  key_usage_snapshot=$(echo "$keys_response" | jq '
    [.data[]? |
      {
        key_name: (.name // .label // "(unnamed key)"),
        key_hash: (.hash // null),
        workspace_id: (.workspace_id // null),
        disabled: (.disabled // false),
        limit: (.limit // null),
        limit_remaining: (.limit_remaining // null),
        usage: (.usage // 0),
        usage_daily: (.usage_daily // null),
        usage_weekly: (.usage_weekly // null),
        usage_monthly: (.usage_monthly // null)
      }
    ] | sort_by(-(.usage // 0))
  ')

  echo "=== REPORT: API KEY USAGE SNAPSHOT (JSON) ==="
  echo "$key_usage_snapshot" | jq '.'

  if [ "$workspaces_available" -eq 1 ]; then
    workspace_usage_snapshot=$(jq -n --argjson ws "$workspaces_response" --argjson keys "$keys_response" '
      ($keys.data // []) as $k |
      ($ws.data // [])
      | map(
          . as $w
          | {
              workspace_id: ($w.id // null),
              workspace_name: ($w.name // $w.slug // $w.id // "unknown"),
              workspace_slug: ($w.slug // null),
              key_count: ([ $k[] | select((.workspace_id // "") == ($w.id // "")) ] | length),
              disabled_key_count: ([ $k[] | select((.workspace_id // "") == ($w.id // "") and ((.disabled // false) == true)) ] | length),
              unlimited_key_count: ([ $k[] | select((.workspace_id // "") == ($w.id // "") and (.limit == null)) ] | length),
              key_usage_total: ([ $k[] | select((.workspace_id // "") == ($w.id // "")) | (.usage // 0) ] | add // 0),
              key_usage_monthly_total: ([ $k[] | select((.workspace_id // "") == ($w.id // "")) | (.usage_monthly // .usage // 0) ] | add // 0),
              key_limit_remaining_total: ([ $k[] | select((.workspace_id // "") == ($w.id // "")) | (.limit_remaining // 0) ] | add // 0)
            }
        )
      | sort_by(-.key_usage_total)
    ')

    echo "=== REPORT: WORKSPACE USAGE SNAPSHOT (JSON) ==="
    echo "$workspace_usage_snapshot" | jq '.'
  fi
else
  key_snapshot=$(echo "$api_response" | jq '{
    key_label: (.data.label // null),
    is_management_key: (.data.is_management_key // false),
    limit: (.data.limit // null),
    limit_remaining: (.data.limit_remaining // null),
    usage: (.data.usage // 0),
    usage_daily: (.data.usage_daily // null),
    usage_weekly: (.data.usage_weekly // null),
    usage_monthly: (.data.usage_monthly // null)
  }')
  echo "=== REPORT: CURRENT KEY SNAPSHOT (JSON) ==="
  echo "$key_snapshot" | jq '.'
fi

account_snapshot=$(jq -n \
  --arg account_balance_usd "$ACCOUNT_BALANCE_USD" \
  --arg account_balance_source "$ACCOUNT_BALANCE_SOURCE" \
  --arg key_limit_remaining "$credits" \
  --arg key_usage_total "$usage" \
  --arg min_balance_threshold "$OPENROUTER_MIN_BALANCE_USD" \
  '{
    account_balance_usd: ($account_balance_usd | tonumber? // null),
    account_balance_source: $account_balance_source,
    key_limit_remaining_aggregate: ($key_limit_remaining | tonumber? // null),
    key_usage_total_aggregate: ($key_usage_total | tonumber? // null),
    min_balance_threshold: ($min_balance_threshold | tonumber? // null)
  }')

echo "=== REPORT: ACCOUNT BALANCE SNAPSHOT (JSON) ==="
echo "$account_snapshot" | jq '.'

if [ "$BALANCE_UNKNOWN" -eq 1 ] || [ "$ACCOUNT_BALANCE_USD" = "null" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "OpenRouter Remaining Credits Not Reported" \
    --arg details "The authenticated key does not expose limit_remaining. Check key/workspace limits in https://openrouter.ai/settings/keys and billing in https://openrouter.ai/settings/credits." \
    --arg severity "2" \
    --arg next_steps "Set key or workspace limits if you need API-visible remaining balance for automation." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
elif [ "$(echo "$ACCOUNT_BALANCE_USD < $balance_threshold" | bc -l)" -eq 1 ]; then
  context="Current remaining balance is \$$ACCOUNT_BALANCE_USD (source: $ACCOUNT_BALANCE_SOURCE), which is below the minimum threshold of \$$balance_threshold. Total usage: \$$usage."
  if [ "$is_management_key" = "true" ]; then
    context="Account remaining credits are \$$ACCOUNT_BALANCE_USD from /credits (total_credits - total_usage), below threshold \$$balance_threshold. Aggregated key limit_remaining is \$$credits. Aggregated usage: \$$usage."
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