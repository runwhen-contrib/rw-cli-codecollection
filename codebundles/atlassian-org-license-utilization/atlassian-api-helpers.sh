#!/usr/bin/env bash
# Shared helpers for Atlassian Organizations REST API (read-only).
set -euo pipefail

ATLASSIAN_API_BASE="${ATLASSIAN_API_BASE:-https://api.atlassian.com/admin}"

: "${ATLASSIAN_ORG_ID:?Must set ATLASSIAN_ORG_ID}"

ATLASSIAN_ORG_API_KEY="${ATLASSIAN_ORG_API_KEY:-${atlassian_org_api_key:-}}"
: "${ATLASSIAN_ORG_API_KEY:?Must set ATLASSIAN_ORG_API_KEY or atlassian_org_api_key secret}"

LICENSE_UTILIZATION_MIN_PERCENT="${LICENSE_UTILIZATION_MIN_PERCENT:-70}"
USER_TIER_PROXIMITY_PERCENT="${USER_TIER_PROXIMITY_PERCENT:-80}"
INACTIVE_DAYS_THRESHOLD="${INACTIVE_DAYS_THRESHOLD:-90}"
PRODUCTS="${PRODUCTS:-All}"
MAX_API_RETRIES="${MAX_API_RETRIES:-5}"
API_BACKOFF_SECONDS="${API_BACKOFF_SECONDS:-2}"

_atlassian_tmp_dir=""
_atlassian_managed_accounts_file=""
_atlassian_workspaces_file=""

atlassian_cleanup() {
  if [[ -n "${_atlassian_tmp_dir}" && -d "${_atlassian_tmp_dir}" ]]; then
    rm -rf "${_atlassian_tmp_dir}"
  fi
}

atlassian_init_cache() {
  _atlassian_tmp_dir="$(mktemp -d)"
  _atlassian_managed_accounts_file="${_atlassian_tmp_dir}/managed_accounts.json"
  _atlassian_workspaces_file="${_atlassian_tmp_dir}/workspaces.json"
  echo "[]" > "${_atlassian_managed_accounts_file}"
  echo "[]" > "${_atlassian_workspaces_file}"
}

atlassian_product_allowed() {
  local key="$1"
  if [[ "${PRODUCTS}" == "All" || -z "${PRODUCTS}" ]]; then
    return 0
  fi
  local normalized
  normalized="$(echo "${PRODUCTS}" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -Fx "${key}" || true)"
  [[ -n "${normalized}" ]]
}

atlassian_normalize_product_key() {
  local raw="$1"
  case "${raw}" in
    jira-core|jira_core) echo "jira-core" ;;
    jira-software|jira_software) echo "jira-software" ;;
    jira-servicedesk|jira_service_management|jira-service-management) echo "jira-servicedesk" ;;
    confluence) echo "confluence" ;;
    loom) echo "loom" ;;
    *) echo "${raw}" ;;
  esac
}

atlassian_is_active_date() {
  local last_active="$1"
  local threshold_days="$2"
  if [[ -z "${last_active}" || "${last_active}" == "null" ]]; then
    return 1
  fi
  local active_epoch now_epoch cutoff_epoch
  active_epoch="$(date -d "${last_active}" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "${last_active}" +%s 2>/dev/null || echo 0)"
  if [[ "${active_epoch}" == "0" ]]; then
    active_epoch="$(date -d "${last_active}T00:00:00Z" +%s 2>/dev/null || echo 0)"
  fi
  if [[ "${active_epoch}" == "0" ]]; then
    return 1
  fi
  now_epoch="$(date -u +%s)"
  cutoff_epoch=$((now_epoch - threshold_days * 86400))
  [[ "${active_epoch}" -ge "${cutoff_epoch}" ]]
}

atlassian_http_request() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
  local attempt=0
  local response http_code
  local err_file
  err_file="$(mktemp)"

  while (( attempt < MAX_API_RETRIES )); do
    if [[ "${method}" == "GET" ]]; then
      response="$(curl -sS -w $'\n%{http_code}' -X GET "${url}" \
        -H "Authorization: Bearer ${ATLASSIAN_ORG_API_KEY}" \
        -H "Accept: application/json" 2>"${err_file}")" || {
        cat "${err_file}" >&2
        rm -f "${err_file}"
        return 1
      }
    else
      response="$(curl -sS -w $'\n%{http_code}' -X POST "${url}" \
        -H "Authorization: Bearer ${ATLASSIAN_ORG_API_KEY}" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d "${body}" 2>"${err_file}")" || {
        cat "${err_file}" >&2
        rm -f "${err_file}"
        return 1
      }
    fi

    http_code="${response##*$'\n'}"
    response="${response%$'\n'*}"

    if [[ "${http_code}" == "429" ]]; then
      local reset_wait="${API_BACKOFF_SECONDS}"
      if [[ -n "${response}" ]]; then
        reset_wait="${API_BACKOFF_SECONDS}"
      fi
      sleep "${reset_wait}"
      attempt=$((attempt + 1))
      continue
    fi

    rm -f "${err_file}"
    printf '%s\n' "${http_code}"
    printf '%s' "${response}"
    return 0
  done

  rm -f "${err_file}"
  return 1
}

atlassian_discover_directory_id() {
  if [[ -n "${ATLASSIAN_DIRECTORY_ID:-}" ]]; then
    echo "${ATLASSIAN_DIRECTORY_ID}"
    return 0
  fi

  local url="${ATLASSIAN_API_BASE}/v2/orgs/${ATLASSIAN_ORG_ID}/directories?limit=1"
  local raw http_code body
  raw="$(atlassian_http_request GET "${url}")" || return 1
  http_code="$(echo "${raw}" | head -n1)"
  body="$(echo "${raw}" | tail -n +2)"
  if [[ "${http_code}" != "200" ]]; then
    echo "Failed to list directories (HTTP ${http_code}): ${body}" >&2
    return 1
  fi
  local dir_id
  dir_id="$(echo "${body}" | jq -r '.data[0].directoryId // empty')"
  if [[ -z "${dir_id}" ]]; then
    echo "No directories discovered for organization ${ATLASSIAN_ORG_ID}" >&2
    return 1
  fi
  echo "${dir_id}"
}

atlassian_fetch_managed_accounts() {
  local max_pages="${1:-0}"
  local page=0
  local cursor=""
  local url
  local all_users="[]"
  local raw http_code body next_cursor

  while :; do
    page=$((page + 1))
    if [[ -n "${cursor}" ]]; then
      url="${ATLASSIAN_API_BASE}/v1/orgs/${ATLASSIAN_ORG_ID}/users?cursor=${cursor}"
    else
      url="${ATLASSIAN_API_BASE}/v1/orgs/${ATLASSIAN_ORG_ID}/users"
    fi

    raw="$(atlassian_http_request GET "${url}")" || return 1
    http_code="$(echo "${raw}" | head -n1)"
    body="$(echo "${raw}" | tail -n +2)"

    if [[ "${http_code}" != "200" ]]; then
      echo "Managed accounts API failed (HTTP ${http_code}): ${body}" >&2
      return 1
    fi

    all_users="$(jq -s '.[0] as $acc | .[1].data as $page | ($acc + $page)' <<< "${all_users} ${body}")"
    next_cursor="$(echo "${body}" | jq -r '.links.next // empty')"
    if [[ -z "${next_cursor}" || "${next_cursor}" == "null" ]]; then
      break
    fi
    cursor="${next_cursor}"
    if [[ "${max_pages}" -gt 0 && "${page}" -ge "${max_pages}" ]]; then
      break
    fi
  done

  echo "${all_users}" > "${_atlassian_managed_accounts_file}"
  printf '%s' "${all_users}"
}

atlassian_fetch_workspaces() {
  local cursor=""
  local page_body='{}'
  local all_ws='[]'
  local raw http_code body next_cursor

  while :; do
    if [[ -n "${cursor}" ]]; then
      page_body="$(jq -n --arg c "${cursor}" '{cursor: $c}')"
    else
      page_body='{}'
    fi

    raw="$(atlassian_http_request POST "${ATLASSIAN_API_BASE}/v2/orgs/${ATLASSIAN_ORG_ID}/workspaces" "${page_body}")" || return 1
    http_code="$(echo "${raw}" | head -n1)"
    body="$(echo "${raw}" | tail -n +2)"

    if [[ "${http_code}" != "200" ]]; then
      echo "Workspaces API failed (HTTP ${http_code}): ${body}" >&2
      return 1
    fi

    all_ws="$(jq -s '.[0] as $acc | .[1].data as $page | ($acc + $page)' <<< "${all_ws} ${body}")"
    next_cursor="$(echo "${body}" | jq -r '.links.next // empty')"
    if [[ -z "${next_cursor}" || "${next_cursor}" == "null" ]]; then
      break
    fi
    cursor="${next_cursor}"
  done

  echo "${all_ws}" > "${_atlassian_workspaces_file}"
  printf '%s' "${all_ws}"
}

atlassian_build_product_stats() {
  local users_json="$1"
  local inactive_days="$2"
  jq --argjson inactive "${inactive_days}" '
    def active_date(d): (d != null and d != "" and d != "null");
    [ .[] | select(.account_status == "active" or .account_status == null) |
      . as $user |
      (.product_access // [])[] |
      select(.key != null) |
      {
        product: .key,
        billable: 1,
        active: (if active_date(.last_active) then
          ( .last_active | split("T")[0] ) as $d |
          (now - ($d + "T00:00:00Z" | fromdateiso8601)) / 86400 <= $inactive
        else false end)
      }
    ] |
    group_by(.product) |
    map({
      product: .[0].product,
      billable_users: length,
      active_users: ([.[] | select(.active)] | length),
      utilization_percent: (if length == 0 then 0 else (([.[] | select(.active)] | length) * 100 / length) end)
    }) |
    sort_by(.product)
  ' <<< "${users_json}"
}

atlassian_append_issue() {
  local issues_json="$1"
  local title="$2"
  local details="$3"
  local severity="$4"
  local next_steps="$5"
  jq \
    --arg title "${title}" \
    --arg details "${details}" \
    --arg severity "${severity}" \
    --arg next_steps "${next_steps}" \
    '. += [{
      title: $title,
      details: $details,
      severity: ($severity | tonumber),
      next_steps: $next_steps
    }]' <<< "${issues_json}"
}

atlassian_api_auth_check() {
  local url="${ATLASSIAN_API_BASE}/v2/orgs/${ATLASSIAN_ORG_ID}/directories?limit=1"
  local raw http_code
  raw="$(atlassian_http_request GET "${url}")" || return 1
  http_code="$(echo "${raw}" | head -n1)"
  [[ "${http_code}" == "200" ]]
}
