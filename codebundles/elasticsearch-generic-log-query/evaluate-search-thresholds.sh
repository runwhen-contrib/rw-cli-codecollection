#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Compares total_hits in search_summary.json to SEARCH_THRESHOLD_MAX_HITS /
# SEARCH_THRESHOLD_MIN_HITS when set. Writes threshold_issues.json
# -----------------------------------------------------------------------------
: "${SEARCH_THRESHOLD_MAX_HITS:=}"
: "${SEARCH_THRESHOLD_MIN_HITS:=}"

SUMMARY_FILE="search_summary.json"
OUTPUT_FILE="threshold_issues.json"
issues_json='[]'

if [[ ! -f "${SUMMARY_FILE}" ]]; then
  issues_json=$(echo "${issues_json}" | jq \
    --arg title "Missing search_summary.json for threshold evaluation" \
    --arg details "Run Run Generic Log Search before evaluating thresholds." \
    --arg severity "3" \
    --arg next_steps "Execute the search task first so search_summary.json exists." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
  echo "${issues_json}" > "${OUTPUT_FILE}"
  exit 0
fi

total_hits=$(jq -r '(.total_hits // 0) | tonumber | floor' "${SUMMARY_FILE}")

if [[ -n "${SEARCH_THRESHOLD_MAX_HITS}" ]]; then
  if [[ "${total_hits}" -gt "${SEARCH_THRESHOLD_MAX_HITS}" ]]; then
    issues_json=$(echo "${issues_json}" | jq \
      --arg title "Search Hit Count Exceeds Maximum Threshold" \
      --arg details "total_hits=${total_hits} max=${SEARCH_THRESHOLD_MAX_HITS}" \
      --arg severity "3" \
      --arg next_steps "Tighten the query, reduce matching documents, or raise SEARCH_THRESHOLD_MAX_HITS if expected." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "next_steps": $next_steps
       }]')
  fi
fi

if [[ -n "${SEARCH_THRESHOLD_MIN_HITS}" ]]; then
  if [[ "${total_hits}" -lt "${SEARCH_THRESHOLD_MIN_HITS}" ]]; then
    issues_json=$(echo "${issues_json}" | jq \
      --arg title "Search Hit Count Below Minimum Threshold" \
      --arg details "total_hits=${total_hits} min=${SEARCH_THRESHOLD_MIN_HITS}" \
      --arg severity "4" \
      --arg next_steps "Verify log ingestion, index pattern, time range in the query, or lower SEARCH_THRESHOLD_MIN_HITS." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "next_steps": $next_steps
       }]')
  fi
fi

echo "${issues_json}" > "${OUTPUT_FILE}"
echo "Threshold evaluation: total_hits=${total_hits} wrote ${OUTPUT_FILE}"
exit 0
