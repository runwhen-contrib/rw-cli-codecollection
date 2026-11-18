#!/usr/bin/env bash
# Lightweight SLI scorer: API reachability, tier headroom, utilization health.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=atlassian-api-helpers.sh
source "${SCRIPT_DIR}/atlassian-api-helpers.sh"

SLI_MAX_USER_PAGES="${SLI_MAX_USER_PAGES:-10}"

trap atlassian_cleanup EXIT
atlassian_init_cache

api_ok=0
tier_ok=1
util_ok=1
details='{}'

if atlassian_api_auth_check; then
  api_ok=1
else
  api_ok=0
fi

if [[ "${api_ok}" -eq 1 ]]; then
  if workspaces_json="$(atlassian_fetch_workspaces 2>/dev/null)"; then
    tier_violations=0
    while IFS= read -r ws; do
      type_key="$(echo "${ws}" | jq -r '.attributes.typeKey // .attributes.type // "unknown"')"
      product_key="$(atlassian_normalize_product_key "${type_key}")"
      if ! atlassian_product_allowed "${product_key}"; then
        continue
      fi
      usage="$(echo "${ws}" | jq -r '.attributes.usage // 0')"
      capacity="$(echo "${ws}" | jq -r '.attributes.capacity // 0')"
      if [[ "${capacity}" -gt 0 ]]; then
        fill_pct=$((usage * 100 / capacity))
        if [[ "${usage}" -gt "${capacity}" || "${fill_pct}" -ge "${USER_TIER_PROXIMITY_PERCENT}" ]]; then
          tier_violations=$((tier_violations + 1))
        fi
      fi
    done < <(echo "${workspaces_json}" | jq -c '.[]')
    if [[ "${tier_violations}" -gt 0 ]]; then
      tier_ok=0
    fi
  fi

  if users_json="$(atlassian_fetch_managed_accounts "${SLI_MAX_USER_PAGES}" 2>/dev/null)"; then
    stats_json="$(atlassian_build_product_stats "${users_json}" "${INACTIVE_DAYS_THRESHOLD}")"
    below=0
    monitored=0
    while IFS= read -r row; do
      product="$(echo "${row}" | jq -r '.product')"
      if ! atlassian_product_allowed "${product}"; then
        continue
      fi
      billable="$(echo "${row}" | jq -r '.billable_users')"
      util="$(echo "${row}" | jq -r '.utilization_percent')"
      if [[ "${billable}" -gt 0 ]]; then
        monitored=$((monitored + 1))
        if [[ "${util}" -lt "${LICENSE_UTILIZATION_MIN_PERCENT}" ]]; then
          below=$((below + 1))
        fi
      fi
    done < <(echo "${stats_json}" | jq -c '.[]')
    if [[ "${monitored}" -gt 0 && "${below}" -gt 0 ]]; then
      util_ok=0
    fi
    details="$(jq -n \
      --argjson api "${api_ok}" \
      --argjson tier "${tier_ok}" \
      --argjson util "${util_ok}" \
      --argjson monitored "${monitored}" \
      --argjson below "${below}" \
      --argjson max_pages "${SLI_MAX_USER_PAGES}" \
      '{api_reachable: $api, tier_headroom_ok: $tier, utilization_ok: $util, monitored_products: $monitored, below_threshold_products: $below, sli_user_pages_cap: $max_pages}')"
  else
    util_ok=0
    details='{"utilization_ok": 0, "reason": "managed-accounts fetch failed"}'
  fi
else
  tier_ok=0
  util_ok=0
  details='{"api_reachable": 0}'
fi

jq -n \
  --argjson api_reachable "${api_ok}" \
  --argjson tier_headroom_ok "${tier_ok}" \
  --argjson utilization_ok "${util_ok}" \
  --argjson details "${details:-{}}" \
  '{
    api_reachable: $api_reachable,
    tier_headroom_ok: $tier_headroom_ok,
    utilization_ok: $utilization_ok,
    details: $details
  }'
