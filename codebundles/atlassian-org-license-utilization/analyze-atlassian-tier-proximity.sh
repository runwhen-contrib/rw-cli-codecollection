#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=atlassian-api-helpers.sh
source "${SCRIPT_DIR}/atlassian-api-helpers.sh"

: "${ATLASSIAN_ORG_NAME:?Must set ATLASSIAN_ORG_NAME}"

OUTPUT_FILE="atlassian_tier_proximity_issues.json"
REPORT_FILE="atlassian_tier_proximity_report.txt"
issues_json='[]'
tier_data_available=false

trap atlassian_cleanup EXIT
atlassian_init_cache

echo "Analyzing billable user counts versus tier limits for organization: ${ATLASSIAN_ORG_NAME}"

if workspaces_json="$(atlassian_fetch_workspaces 2>/dev/null)"; then
  tier_data_available=true
  {
    echo "Atlassian Tier Proximity Analysis (workspaces API)"
    echo "Organization: ${ATLASSIAN_ORG_NAME}"
    echo "Proximity threshold: ${USER_TIER_PROXIMITY_PERCENT}%"
    echo ""
    printf "%-28s %10s %10s %10s %s\n" "Workspace" "Usage" "Capacity" "Fill %" "Status"
    printf "%-28s %10s %10s %10s %s\n" "----------------------------" "----------" "----------" "----------" "------"
  } > "${REPORT_FILE}"

  while IFS= read -r ws; do
    name="$(echo "${ws}" | jq -r '.attributes.name // .id')"
    type_key="$(echo "${ws}" | jq -r '.attributes.typeKey // .attributes.type // "unknown"')"
    product_key="$(atlassian_normalize_product_key "${type_key}")"
    usage="$(echo "${ws}" | jq -r '.attributes.usage // 0')"
    capacity="$(echo "${ws}" | jq -r '.attributes.capacity // 0')"
    status="$(echo "${ws}" | jq -r '.attributes.status // "unknown"')"

    if ! atlassian_product_allowed "${product_key}"; then
      continue
    fi

    fill_pct=0
    ws_status="ok"
    if [[ "${capacity}" -gt 0 ]]; then
      fill_pct=$((usage * 100 / capacity))
      if [[ "${usage}" -gt "${capacity}" ]]; then
        ws_status="OVERAGE"
        issues_json="$(atlassian_append_issue "${issues_json}" \
          "Billable Users Exceed Purchased Tier for \`${product_key}\` in Organization \`${ATLASSIAN_ORG_NAME}\`" \
          "Workspace '${name}' (${product_key}) has ${usage} billable users versus purchased capacity ${capacity} (${fill_pct}% fill). Last-active data may lag up to 24 hours." \
          "3" \
          "Review inactive users for reclamation, suspend unused accounts, or upgrade the ${product_key} subscription tier before renewal.")"
      elif [[ "${fill_pct}" -ge "${USER_TIER_PROXIMITY_PERCENT}" ]]; then
        ws_status="PROXIMITY"
        issues_json="$(atlassian_append_issue "${issues_json}" \
          "Tier Proximity Alert for \`${product_key}\` in Organization \`${ATLASSIAN_ORG_NAME}\`" \
          "Workspace '${name}' is at ${fill_pct}% of purchased tier (${usage}/${capacity} billable seats). Threshold: ${USER_TIER_PROXIMITY_PERCENT}%." \
          "3" \
          "Plan a tier upgrade before the next renewal or reclaim inactive licenses using the companion optimization bundle.")"
      fi
    else
      ws_status="no-capacity"
    fi

    printf "%-28s %10s %10s %10s %s\n" "${name}" "${usage}" "${capacity}" "${fill_pct}" "${ws_status}" >> "${REPORT_FILE}"
  done < <(echo "${workspaces_json}" | jq -c '.[]')

  echo "" >> "${REPORT_FILE}"
  echo "Tier data source: Organizations workspaces API (usage/capacity fields)." >> "${REPORT_FILE}"
else
  echo "Workspaces API unavailable; attempting managed-accounts billable counts only." > "${REPORT_FILE}"
  if users_json="$(atlassian_fetch_managed_accounts 0 2>/dev/null)"; then
    stats_json="$(atlassian_build_product_stats "${users_json}" "${INACTIVE_DAYS_THRESHOLD}")"
    echo "" >> "${REPORT_FILE}"
    echo "Per-product billable counts (tier quantities unavailable):" >> "${REPORT_FILE}"
    while IFS= read -r row; do
      product="$(echo "${row}" | jq -r '.product')"
      if atlassian_product_allowed "${product}"; then
        billable="$(echo "${row}" | jq -r '.billable_users')"
        echo "  ${product}: ${billable} billable users" >> "${REPORT_FILE}"
      fi
    done < <(echo "${stats_json}" | jq -c '.[]')
    issues_json="$(atlassian_append_issue "${issues_json}" \
      "Tier Quantities Unavailable for Organization \`${ATLASSIAN_ORG_NAME}\`" \
      "Workspaces API did not return usage/capacity data. Tier-proximity analysis skipped; billable counts reported only. Commerce/contracts APIs may require additional scopes." \
      "2" \
      "Grant read:workspaces:admin scope to the Organization Admin API key or supply tier quantities manually for proximity alerts.")"
  else
    issues_json="$(atlassian_append_issue "${issues_json}" \
      "Cannot Analyze Tier Proximity for Organization \`${ATLASSIAN_ORG_NAME}\`" \
      "Both workspaces and managed-accounts APIs failed. Unable to correlate billable counts with tier limits." \
      "4" \
      "Verify Organization Admin API key, ATLASSIAN_ORG_ID, and API rate limits.")
  fi
fi

cat "${REPORT_FILE}"
echo "${issues_json}" > "${OUTPUT_FILE}"
echo "Tier proximity analysis completed. Issues saved to ${OUTPUT_FILE}"
