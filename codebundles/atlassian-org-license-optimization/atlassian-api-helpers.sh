#!/usr/bin/env bash
# Shared read-only helpers for Atlassian Organization Admin API.
set -euo pipefail

ATLASSIAN_API_BASE="${ATLASSIAN_API_BASE:-https://api.atlassian.com/admin}"
INVENTORY_CACHE_FILE="${INVENTORY_CACHE_FILE:-atlassian_user_inventory.json}"
DIRECTORY_USERS_CACHE_FILE="${DIRECTORY_USERS_CACHE_FILE:-atlassian_directory_users.json}"
CACHE_MAX_AGE_SECONDS="${CACHE_MAX_AGE_SECONDS:-3600}"

_atlassian_api_key() {
  local key="${ATLASSIAN_ORG_API_KEY:-${atlassian_org_api_key:-}}"
  if [[ -z "$key" ]]; then
    echo "ERROR: ATLASSIAN_ORG_API_KEY (or atlassian_org_api_key secret) is required." >&2
    return 1
  fi
  printf '%s' "$key"
}

_atlassian_curl() {
  local method="$1"
  local url="$2"
  local api_key
  api_key="$(_atlassian_api_key)" || return 1
  curl -sS -X "$method" \
    -H "Authorization: Bearer ${api_key}" \
    -H "Accept: application/json" \
    "$url"
}

_cache_is_fresh() {
  local cache_file="$1"
  [[ -f "$cache_file" ]] || return 1
  local age
  age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file") ))
  [[ "$age" -le "$CACHE_MAX_AGE_SECONDS" ]]
}

discover_directory_id() {
  if [[ -n "${ATLASSIAN_DIRECTORY_ID:-}" ]]; then
    printf '%s' "$ATLASSIAN_DIRECTORY_ID"
    return 0
  fi

  local response
  if ! response="$(_atlassian_curl GET "${ATLASSIAN_API_BASE}/v2/orgs/${ATLASSIAN_ORG_ID}/directories")"; then
    return 1
  fi

  local dir_id
  dir_id=$(echo "$response" | jq -r '.data[0].directoryId // .data[0].id // empty')
  if [[ -z "$dir_id" || "$dir_id" == "null" ]]; then
    echo "ERROR: Could not auto-discover directory ID for org ${ATLASSIAN_ORG_ID}." >&2
    return 1
  fi
  printf '%s' "$dir_id"
}

_load_mock_inventory() {
  local mock_file="${ATLASSIAN_MOCK_INVENTORY:-}"
  if [[ -n "$mock_file" && -f "$mock_file" ]]; then
    cp "$mock_file" "$INVENTORY_CACHE_FILE"
    return 0
  fi
  return 1
}

_load_mock_directory_users() {
  local mock_file="${ATLASSIAN_MOCK_DIRECTORY_USERS:-}"
  if [[ -n "$mock_file" && -f "$mock_file" ]]; then
    cp "$mock_file" "$DIRECTORY_USERS_CACHE_FILE"
    return 0
  fi
  return 1
}

fetch_managed_users_page() {
  local cursor="${1:-}"
  local url="${ATLASSIAN_API_BASE}/v1/orgs/${ATLASSIAN_ORG_ID}/users"
  if [[ -n "$cursor" ]]; then
    url="${url}?cursor=${cursor}"
  fi
  _atlassian_curl GET "$url"
}

ensure_user_inventory() {
  if _cache_is_fresh "$INVENTORY_CACHE_FILE"; then
    return 0
  fi
  if _load_mock_inventory; then
    return 0
  fi

  local all_users='[]'
  local cursor=""
  local page=0
  local max_pages="${ATLASSIAN_MAX_PAGES:-0}"
  local start_ts
  start_ts=$(date +%s)

  while :; do
    page=$((page + 1))
    if [[ "$max_pages" -gt 0 && "$page" -gt "$max_pages" ]]; then
      echo "WARNING: Stopped pagination at page limit (${max_pages}); inventory may be partial." >&2
      break
    fi
    if [[ -n "${TIMEOUT_SECONDS:-}" ]]; then
      local elapsed=$(( $(date +%s) - start_ts ))
      if [[ "$elapsed" -ge "$TIMEOUT_SECONDS" ]]; then
        echo "WARNING: TIMEOUT_SECONDS (${TIMEOUT_SECONDS}) exceeded during user inventory fetch." >&2
        break
      fi
    fi

    local response
    if ! response="$(fetch_managed_users_page "$cursor")"; then
      echo "ERROR: Failed to fetch managed users page ${page}." >&2
      return 1
    fi

    if echo "$response" | jq -e '.message? // .errorMessage? // empty' >/dev/null 2>&1; then
      local err
      err=$(echo "$response" | jq -r '.message // .errorMessage // "unknown API error"')
      echo "ERROR: Atlassian API error: ${err}" >&2
      return 1
    fi

    local page_users
    page_users=$(echo "$response" | jq -c '.data // []')
    all_users=$(jq -s 'add' <(echo "$all_users") <(echo "$page_users"))

    cursor=$(echo "$response" | jq -r '.links.next // empty')
    [[ -n "$cursor" && "$cursor" != "null" ]] || break
  done

  jq -n \
    --arg org_id "$ATLASSIAN_ORG_ID" \
    --arg org_name "${ATLASSIAN_ORG_NAME:-}" \
    --arg fetched_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson users "$all_users" \
    '{
      org_id: $org_id,
      org_name: $org_name,
      fetched_at: $fetched_at,
      partial: false,
      users: $users
    }' > "$INVENTORY_CACHE_FILE"
}

fetch_directory_users_page() {
  local directory_id="$1"
  local cursor="${2:-}"
  local url="${ATLASSIAN_API_BASE}/v2/orgs/${ATLASSIAN_ORG_ID}/directories/${directory_id}/users?limit=100"
  if [[ -n "$cursor" ]]; then
    url="${url}&cursor=${cursor}"
  fi
  _atlassian_curl GET "$url"
}

ensure_directory_users() {
  if _cache_is_fresh "$DIRECTORY_USERS_CACHE_FILE"; then
    return 0
  fi
  if _load_mock_directory_users; then
    return 0
  fi

  local directory_id
  directory_id="$(discover_directory_id)" || return 1

  local all_users='[]'
  local cursor=""
  local page=0
  local max_pages="${ATLASSIAN_MAX_PAGES:-0}"

  while :; do
    page=$((page + 1))
    if [[ "$max_pages" -gt 0 && "$page" -gt "$max_pages" ]]; then
      echo "WARNING: Stopped directory user pagination at page limit (${max_pages})." >&2
      break
    fi

    local response
    if ! response="$(fetch_directory_users_page "$directory_id" "$cursor")"; then
      echo "ERROR: Failed to fetch directory users page ${page}." >&2
      return 1
    fi

    local page_users
    page_users=$(echo "$response" | jq -c '.data // []')
    all_users=$(jq -s 'add' <(echo "$all_users") <(echo "$page_users"))

    cursor=$(echo "$response" | jq -r '.links.next // empty')
    [[ -n "$cursor" && "$cursor" != "null" ]] || break
  done

  jq -n \
    --arg org_id "$ATLASSIAN_ORG_ID" \
    --arg directory_id "$directory_id" \
    --arg fetched_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson users "$all_users" \
    '{
      org_id: $org_id,
      directory_id: $directory_id,
      fetched_at: $fetched_at,
      partial: false,
      users: $users
    }' > "$DIRECTORY_USERS_CACHE_FILE"
}

days_since() {
  local iso_date="$1"
  if [[ -z "$iso_date" || "$iso_date" == "null" ]]; then
    printf '%s' "999999"
    return 0
  fi
  local now epoch then_epoch
  now=$(date +%s)
  then_epoch=$(date -d "$iso_date" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${iso_date%%.*}" +%s 2>/dev/null || echo 0)
  if [[ "$then_epoch" -eq 0 ]]; then
    printf '%s' "999999"
    return 0
  fi
  echo $(( (now - then_epoch) / 86400 ))
}

product_filter_active() {
  local products="${PRODUCTS:-All}"
  if [[ "$products" == "All" || -z "$products" ]]; then
    return 0
  fi
  local key="$1"
  IFS=',' read -ra wanted <<< "$products"
  for p in "${wanted[@]}"; do
    p="${p// /}"
    if [[ "$p" == "$key" ]]; then
      return 0
    fi
  done
  return 1
}

append_api_access_issue() {
  local issues_json="$1"
  local org_name="${ATLASSIAN_ORG_NAME:-$ATLASSIAN_ORG_ID}"
  local details="$2"
  echo "$issues_json" | jq \
    --arg title "Cannot Access Atlassian Organization \`${org_name}\`" \
    --arg details "$details" \
    --arg severity "4" \
    --arg next_steps "Verify the Organization Admin API key has org-admin read permissions. Confirm ATLASSIAN_ORG_ID is correct. Re-run after updating the atlassian_org_api_key secret." \
    '. += [{
      "title": $title,
      "details": $details,
      "severity": ($severity | tonumber),
      "next_steps": $next_steps
    }]'
}
