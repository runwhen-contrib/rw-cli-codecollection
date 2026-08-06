#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=atlassian-api-helpers.sh
source "${SCRIPT_DIR}/atlassian-api-helpers.sh"

: "${ATLASSIAN_ORG_NAME:?Must set ATLASSIAN_ORG_NAME}"

OUTPUT_FILE="atlassian_utilization_threshold_issues.json"
REPORT_FILE="atlassian_utilization_threshold_report.txt"
issues_json='[]'

trap atlassian_cleanup EXIT
atlassian_init_cache

echo "Evaluating license utilization thresholds for organization: ${ATLASSIAN_ORG_NAME}"
echo "Minimum acceptable utilization: ${LICENSE_UTILIZATION_MIN_PERCENT}% (active/billable within ${INACTIVE_DAYS_THRESHOLD} days)"

if ! users_json="$(atlassian_fetch_managed_accounts 0)"; then
  issues_json="$(atlassian_append_issue "${issues_json}" \
    "Cannot Evaluate Utilization for Organization \`${ATLASSIAN_ORG_NAME}\`" \
    "Managed accounts API call failed while evaluating utilization thresholds." \
    "4" \
    "Verify Organization Admin API key and ATLASSIAN_ORG_ID; retry after rate-limit backoff.")"
  echo "${issues_json}" > "${OUTPUT_FILE}"
  exit 0
fi

stats_json="$(atlassian_build_product_stats "${users_json}" "${INACTIVE_DAYS_THRESHOLD}")"

{
  echo "Atlassian License Utilization Threshold Evaluation"
  echo "Organization: ${ATLASSIAN_ORG_NAME}"
  echo "Threshold: ${LICENSE_UTILIZATION_MIN_PERCENT}% active/billable"
  echo "Inactive window: ${INACTIVE_DAYS_THRESHOLD} days"
  echo ""
  printf "%-24s %8s %8s %8s %s\n" "Product" "Billable" "Active" "Util %" "Result"
  printf "%-24s %8s %8s %8s %s\n" "------------------------" "--------" "--------" "--------" "------"
} > "${REPORT_FILE}"

while IFS= read -r row; do
  product="$(echo "${row}" | jq -r '.product')"
  if ! atlassian_product_allowed "${product}"; then
    continue
  fi
  billable="$(echo "${row}" | jq -r '.billable_users')"
  active="$(echo "${row}" | jq -r '.active_users')"
  util="$(echo "${row}" | jq -r '.utilization_percent')"
  result="PASS"

  if [[ "${billable}" -eq 0 ]]; then
    result="SKIP"
  elif [[ "${util}" -lt "${LICENSE_UTILIZATION_MIN_PERCENT}" ]]; then
    result="BELOW"
    severity="3"
    if [[ "${util}" -lt $((LICENSE_UTILIZATION_MIN_PERCENT / 2)) ]]; then
      severity="4"
    fi
    issues_json="$(atlassian_append_issue "${issues_json}" \
      "Low License Utilization for \`${product}\` in Organization \`${ATLASSIAN_ORG_NAME}\`" \
      "Product ${product}: ${active}/${billable} active/billable users (${util}% utilization). Expected at least ${LICENSE_UTILIZATION_MIN_PERCENT}%. Last-active data may lag up to 24 hours." \
      "${severity}" \
      "Review inactive users in ${product}; suspend or remove access for long-idle accounts; consider right-sizing the subscription tier at renewal.")"
  fi

  printf "%-24s %8s %8s %8s %s\n" "${product}" "${billable}" "${active}" "${util}" "${result}" >> "${REPORT_FILE}"
done < <(echo "${stats_json}" | jq -c '.[]')

cat "${REPORT_FILE}"
echo "${issues_json}" > "${OUTPUT_FILE}"
echo "Utilization threshold evaluation completed. Issues saved to ${OUTPUT_FILE}"
