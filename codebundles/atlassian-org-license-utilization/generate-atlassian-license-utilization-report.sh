#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=atlassian-api-helpers.sh
source "${SCRIPT_DIR}/atlassian-api-helpers.sh"

: "${ATLASSIAN_ORG_NAME:?Must set ATLASSIAN_ORG_NAME}"

OUTPUT_FILE="atlassian_utilization_report_issues.json"
REPORT_FILE="atlassian_utilization_report.txt"
issues_json='[]'

trap atlassian_cleanup EXIT
atlassian_init_cache

echo "Generating Atlassian license utilization report for organization: ${ATLASSIAN_ORG_NAME} (${ATLASSIAN_ORG_ID})"
echo "Note: last-active timestamps may lag up to 24 hours per Atlassian API documentation."

if ! users_json="$(atlassian_fetch_managed_accounts 0)"; then
  issues_json="$(atlassian_append_issue "${issues_json}" \
    "Cannot Access Atlassian Organization \`${ATLASSIAN_ORG_NAME}\`" \
    "Managed accounts API call failed. Verify Organization Admin API key and ATLASSIAN_ORG_ID." \
    "4" \
    "Confirm the API key has Organization Admin role and read access; verify ATLASSIAN_ORG_ID in Atlassian Administration.")"
  echo "${issues_json}" > "${OUTPUT_FILE}"
  exit 0
fi

total_users="$(echo "${users_json}" | jq 'length')"
stats_json="$(atlassian_build_product_stats "${users_json}" "${INACTIVE_DAYS_THRESHOLD}")"

filtered_stats='[]'
while IFS= read -r row; do
  product="$(echo "${row}" | jq -r '.product')"
  if atlassian_product_allowed "${product}"; then
    filtered_stats="$(jq -s '.[0] + [.[1]]' <<< "${filtered_stats} ${row}")"
  fi
done < <(echo "${stats_json}" | jq -c '.[]')

{
  echo "Atlassian Organization License Utilization Report"
  echo "Organization: ${ATLASSIAN_ORG_NAME} (${ATLASSIAN_ORG_ID})"
  echo "Inactive threshold: ${INACTIVE_DAYS_THRESHOLD} days"
  echo "Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo ""
  echo "Managed accounts scanned: ${total_users}"
  echo ""
  printf "%-24s %12s %12s %12s\n" "Product" "Billable" "Active" "Util %"
  printf "%-24s %12s %12s %12s\n" "------------------------" "------------" "------------" "------------"
} > "${REPORT_FILE}"

org_billable=0
org_active=0

while IFS= read -r row; do
  product="$(echo "${row}" | jq -r '.product')"
  billable="$(echo "${row}" | jq -r '.billable_users')"
  active="$(echo "${row}" | jq -r '.active_users')"
  util="$(echo "${row}" | jq -r '.utilization_percent')"
  printf "%-24s %12s %12s %12s\n" "${product}" "${billable}" "${active}" "${util}" >> "${REPORT_FILE}"
  org_billable=$((org_billable + billable))
  org_active=$((org_active + active))
done < <(echo "${filtered_stats}" | jq -c '.[]')

org_util=0
if [[ "${org_billable}" -gt 0 ]]; then
  org_util=$((org_active * 100 / org_billable))
fi

{
  echo ""
  echo "Organization-wide summary:"
  echo "  Total billable seats (monitored products): ${org_billable}"
  echo "  Total active users (within ${INACTIVE_DAYS_THRESHOLD}d): ${org_active}"
  echo "  Weighted utilization: ${org_util}%"
} >> "${REPORT_FILE}"

echo "${filtered_stats}" | jq '.' > atlassian_utilization_report.json
cat "${REPORT_FILE}"

if [[ "${total_users}" -eq 0 ]]; then
  issues_json="$(atlassian_append_issue "${issues_json}" \
    "No Managed Accounts Found for Organization \`${ATLASSIAN_ORG_NAME}\`" \
    "The managed accounts API returned zero users for organization ${ATLASSIAN_ORG_ID}." \
    "2" \
    "Verify the organization has managed accounts and the API key has Organization Admin permissions.")"
fi

echo "${issues_json}" > "${OUTPUT_FILE}"
echo "Analysis completed. Report saved to ${REPORT_FILE}; issues in ${OUTPUT_FILE}"
