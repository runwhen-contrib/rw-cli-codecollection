#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# POST ELASTICSEARCH_QUERY_BODY to ${BASE}/${INDEX}/_search. Writes:
#   search_summary.json  — total_hits, sample_hits, http_code, error_message
#   search_issues.json — issues JSON array for runbook
# -----------------------------------------------------------------------------
: "${ELASTICSEARCH_BASE_URL:?Must set ELASTICSEARCH_BASE_URL}"
: "${ELASTICSEARCH_INDEX_PATTERN:?Must set ELASTICSEARCH_INDEX_PATTERN}"
: "${ELASTICSEARCH_QUERY_BODY:?Must set ELASTICSEARCH_QUERY_BODY}"
: "${REQUEST_TIMEOUT_SECONDS:=60}"

SUMMARY_FILE="search_summary.json"
ISSUES_FILE="search_issues.json"
issues_json='[]'

# shellcheck source=/dev/null
load_credentials() {
  if [[ -n "${elasticsearch_credentials:-}" ]]; then
    local creds_raw
    if [[ -f "${elasticsearch_credentials}" ]]; then
      creds_raw=$(cat "${elasticsearch_credentials}")
    else
      creds_raw="${elasticsearch_credentials}"
    fi
    if echo "${creds_raw}" | jq -e . >/dev/null 2>&1; then
      export ELASTICSEARCH_USERNAME
      ELASTICSEARCH_USERNAME=$(echo "${creds_raw}" | jq -r '.ELASTICSEARCH_USERNAME // empty')
      export ELASTICSEARCH_PASSWORD
      ELASTICSEARCH_PASSWORD=$(echo "${creds_raw}" | jq -r '.ELASTICSEARCH_PASSWORD // empty')
      export ELASTICSEARCH_API_KEY
      ELASTICSEARCH_API_KEY=$(echo "${creds_raw}" | jq -r '.ELASTICSEARCH_API_KEY // empty')
    fi
  fi
}

load_credentials

if ! echo "${ELASTICSEARCH_QUERY_BODY}" | jq -e . >/dev/null 2>&1; then
  issues_json=$(echo "${issues_json}" | jq \
    --arg title "Invalid JSON in ELASTICSEARCH_QUERY_BODY" \
    --arg details "Body must be valid JSON for Content-Type: application/json." \
    --arg severity "2" \
    --arg next_steps "Fix ELASTICSEARCH_QUERY_BODY to be valid JSON (jq . validates)." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
  echo "${issues_json}" > "${ISSUES_FILE}"
  echo '{"total_hits":0,"sample_hits":[],"http_code":0,"error_message":"invalid query JSON"}' > "${SUMMARY_FILE}"
  echo "Invalid query JSON"
  exit 0
fi

BASE="${ELASTICSEARCH_BASE_URL%/}"
SEARCH_URL="${BASE}/${ELASTICSEARCH_INDEX_PATTERN}/_search"

curl_args=(
  -sS
  --max-time "${REQUEST_TIMEOUT_SECONDS}"
  -H "Content-Type: application/json"
  -w "\n%{http_code}"
)

if [[ -n "${ELASTICSEARCH_API_KEY:-}" ]]; then
  curl_args+=(-H "Authorization: ApiKey ${ELASTICSEARCH_API_KEY}")
elif [[ -n "${ELASTICSEARCH_USERNAME:-}" && -n "${ELASTICSEARCH_PASSWORD:-}" ]]; then
  curl_args+=(-u "${ELASTICSEARCH_USERNAME}:${ELASTICSEARCH_PASSWORD}")
fi

if ! curl_out=$(echo "${ELASTICSEARCH_QUERY_BODY}" | curl "${curl_args[@]}" -X POST --data-binary @- "${SEARCH_URL}" 2>/tmp/es_search_err.$$); then
  err=$(cat /tmp/es_search_err.$$ || true)
  rm -f /tmp/es_search_err.$$
  issues_json=$(echo "${issues_json}" | jq \
    --arg title "Elasticsearch Search Request Failed for \`${SEARCH_URL}\`" \
    --arg details "curl error: ${err}" \
    --arg severity "2" \
    --arg next_steps "Verify URL, index pattern, auth, and cluster health." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
  echo "${issues_json}" > "${ISSUES_FILE}"
  jq -n \
    --arg err "${err}" \
    '{total_hits: 0, sample_hits: [], http_code: 0, error_message: $err}' > "${SUMMARY_FILE}"
  echo "Search request failed"
  exit 0
fi
rm -f /tmp/es_search_err.$$

http_code=$(echo "${curl_out}" | tail -n1)
body=$(echo "${curl_out}" | sed '$d')

if [[ ! "${http_code}" =~ ^[0-9]+$ ]]; then
  http_code="000"
  body="${curl_out}"
fi

if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
  echo "${body}" | jq -c \
    --arg hc "${http_code}" \
    '{
      total_hits: ((.hits.total | if type == "object" then .value else . end) // 0),
      sample_hits: ([.hits.hits[]? | {_id: ._id, _index: ._index, _source: ._source}] | .[0:20]),
      http_code: ($hc | tonumber),
      error_message: ""
    }' > "${SUMMARY_FILE}"
else
  err_msg=$(echo "${body}" | head -c 4096 | tr -d '\0' || true)
  issues_json=$(echo "${issues_json}" | jq \
    --arg title "Elasticsearch Search Returned HTTP ${http_code}" \
    --arg details "POST ${SEARCH_URL} failed. Body: ${err_msg}" \
    --arg severity "2" \
    --arg next_steps "Check index pattern, mappings, query syntax, and permissions." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
  jq -n \
    --arg hc "${http_code}" \
    --arg em "${err_msg}" \
    '{total_hits: 0, sample_hits: [], http_code: ($hc | tonumber), error_message: $em}' > "${SUMMARY_FILE}"
fi

echo "${issues_json}" > "${ISSUES_FILE}"

echo "Search complete. Wrote ${SUMMARY_FILE} and ${ISSUES_FILE}"
exit 0
