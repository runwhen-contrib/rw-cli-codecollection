#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=atlassian-api-helpers.sh
source "${SCRIPT_DIR}/atlassian-api-helpers.sh"

: "${ATLASSIAN_ORG_NAME:?Must set ATLASSIAN_ORG_NAME}"

OUTPUT_FILE="atlassian_active_trend_issues.json"
REPORT_FILE="atlassian_active_trend_report.txt"
issues_json='[]'

trap atlassian_cleanup EXIT
atlassian_init_cache

echo "Reporting active user trends for organization: ${ATLASSIAN_ORG_NAME}"

if ! users_json="$(atlassian_fetch_managed_accounts 0)"; then
  issues_json="$(atlassian_append_issue "${issues_json}" \
    "Cannot Report Active User Trends for Organization \`${ATLASSIAN_ORG_NAME}\`" \
    "Managed accounts API call failed while building active-user trend summary." \
    "4" \
    "Verify Organization Admin API key and ATLASSIAN_ORG_ID.")"
  echo "${issues_json}" > "${OUTPUT_FILE}"
  exit 0
fi

stats_json="$(atlassian_build_product_stats "${users_json}" "${INACTIVE_DAYS_THRESHOLD}")"

# Secondary window for trend comparison (half of inactive threshold, min 30 days)
recent_days=$((INACTIVE_DAYS_THRESHOLD / 2))
if [[ "${recent_days}" -lt 30 ]]; then
  recent_days=30
fi
recent_stats_json="$(atlassian_build_product_stats "${users_json}" "${recent_days}")"

{
  echo "Atlassian Active User Trends"
  echo "Organization: ${ATLASSIAN_ORG_NAME}"
  echo "Primary active window: ${INACTIVE_DAYS_THRESHOLD} days"
  echo "Recent active window: ${recent_days} days (for share comparison)"
  echo ""
  printf "%-22s %8s %8s %8s %8s %s\n" "Product" "Billable" "Active" "Recent" "Share %" "Trend"
  printf "%-22s %8s %8s %8s %8s %s\n" "----------------------" "--------" "--------" "--------" "--------" "-----"
} > "${REPORT_FILE}"

while IFS= read -r row; do
  product="$(echo "${row}" | jq -r '.product')"
  if ! atlassian_product_allowed "${product}"; then
    continue
  fi
  billable="$(echo "${row}" | jq -r '.billable_users')"
  active="$(echo "${row}" | jq -r '.active_users')"
  util="$(echo "${row}" | jq -r '.utilization_percent')"
  recent_active="$(echo "${recent_stats_json}" | jq -r --arg p "${product}" '[.[] | select(.product == $p)][0].active_users // 0')"
  share_pct="${util}"
  trend="stable"

  if [[ "${billable}" -gt 0 && "${recent_active}" -lt "${active}" ]]; then
    trend="declining-recent"
  elif [[ "${billable}" -gt 0 && "${util}" -lt "${LICENSE_UTILIZATION_MIN_PERCENT}" ]]; then
    trend="low-share"
  elif [[ "${billable}" -gt 0 && "${util}" -ge 80 ]]; then
    trend="healthy"
  fi

  printf "%-22s %8s %8s %8s %8s %s\n" "${product}" "${billable}" "${active}" "${recent_active}" "${share_pct}" "${trend}" >> "${REPORT_FILE}"

  if [[ "${trend}" == "declining-recent" || "${trend}" == "low-share" ]]; then
    severity="2"
    if [[ "${util}" -lt "${LICENSE_UTILIZATION_MIN_PERCENT}" ]]; then
      severity="3"
    fi
    issues_json="$(atlassian_append_issue "${issues_json}" \
      "Declining Active User Share for \`${product}\` in Organization \`${ATLASSIAN_ORG_NAME}\`" \
      "Product ${product}: ${active}/${billable} active within ${INACTIVE_DAYS_THRESHOLD}d (${share_pct}% share) but only ${recent_active} active within ${recent_days}d. Indicates declining engagement versus billable seats." \
      "${severity}" \
      "Review renewal sizing for ${product}; audit inactive users; coordinate with finance on right-sizing before contract renewal.")"
  fi
done < <(echo "${stats_json}" | jq -c '.[]')

{
  echo ""
  echo "Note: Trend analysis uses last_active from managed-accounts product_access."
  echo "Last-active data may lag up to 24 hours per Atlassian API documentation."
} >> "${REPORT_FILE}"

cat "${REPORT_FILE}"
echo "${issues_json}" > "${OUTPUT_FILE}"
echo "Active user trend report completed. Issues saved to ${OUTPUT_FILE}"
