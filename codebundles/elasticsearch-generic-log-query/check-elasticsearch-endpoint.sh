#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Verifies HTTP(S) reachability of ELASTICSEARCH_BASE_URL (optional auth).
# Writes JSON array of issues to endpoint_check_issues.json
# -----------------------------------------------------------------------------
: "${ELASTICSEARCH_BASE_URL:?Must set ELASTICSEARCH_BASE_URL}"
: "${REQUEST_TIMEOUT_SECONDS:=60}"

OUTPUT_FILE="endpoint_check_issues.json"
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

BASE="${ELASTICSEARCH_BASE_URL%/}"
PROBE_URL="${BASE}/"

curl_args=(
  -sS
  --max-time "${REQUEST_TIMEOUT_SECONDS}"
  -o /tmp/es_probe_body.$$
  -w "%{http_code}"
)

if [[ -n "${ELASTICSEARCH_API_KEY:-}" ]]; then
  curl_args+=(-H "Authorization: ApiKey ${ELASTICSEARCH_API_KEY}")
elif [[ -n "${ELASTICSEARCH_USERNAME:-}" && -n "${ELASTICSEARCH_PASSWORD:-}" ]]; then
  curl_args+=(-u "${ELASTICSEARCH_USERNAME}:${ELASTICSEARCH_PASSWORD}")
fi

http_code="000"
curl_err=""
if ! http_code=$(curl "${curl_args[@]}" "${PROBE_URL}" 2>/tmp/es_probe_err.$$); then
  curl_err=$(cat /tmp/es_probe_err.$$ || true)
fi
rm -f /tmp/es_probe_err.$$

body_preview=""
if [[ -f /tmp/es_probe_body.$$ ]]; then
  body_preview=$(head -c 2048 /tmp/es_probe_body.$$ | tr -d '\0' || true)
fi
rm -f /tmp/es_probe_body.$$

echo "Elasticsearch endpoint probe: ${PROBE_URL}"
echo "HTTP status: ${http_code}"
if [[ -n "${body_preview}" ]]; then
  echo "Response preview (first 2KB):"
  echo "${body_preview}"
fi

if [[ "${http_code}" == "000" ]]; then
  issues_json=$(echo "${issues_json}" | jq \
    --arg title "Elasticsearch Endpoint Unreachable at \`${BASE}\`" \
    --arg hc "${http_code}" \
    --arg cerr "${curl_err}" \
    --arg severity "2" \
    --arg next_steps "Verify ELASTICSEARCH_BASE_URL, network paths, TLS, and firewall rules. Test with curl -v against the base URL." \
    '. += [{
       "title": $title,
       "details": ("curl failed to complete (HTTP " + $hc + "). " + $cerr),
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
elif [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
  issues_json=$(echo "${issues_json}" | jq \
    --arg title "Elasticsearch Endpoint Returned Non-Success HTTP ${http_code} for \`${BASE}\`" \
    --arg url "${PROBE_URL}" \
    --arg preview "${body_preview}" \
    --arg severity "3" \
    --arg next_steps "Confirm credentials, Elasticsearch is running, and the base URL targets the HTTP API (port 9200 for OSS/Elastic Cloud)." \
    '. += [{
       "title": $title,
       "details": ("Expected 2xx from GET " + $url + ". Body preview: " + $preview),
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
fi

echo "${issues_json}" > "${OUTPUT_FILE}"
echo "Wrote ${OUTPUT_FILE}"
exit 0
