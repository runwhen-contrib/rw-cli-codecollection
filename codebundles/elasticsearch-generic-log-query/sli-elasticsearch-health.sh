#!/usr/bin/env bash
set -euo pipefail
# Lightweight probe for SLI: prints 1 if GET _cluster/health returns 2xx, else 0.
: "${ELASTICSEARCH_BASE_URL:?Must set ELASTICSEARCH_BASE_URL}"
: "${REQUEST_TIMEOUT_SECONDS:=15}"

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
URL="${BASE}/_cluster/health?wait_for_status=yellow&timeout=5s"

curl_args=(
  -sS
  --max-time "${REQUEST_TIMEOUT_SECONDS}"
  -o /dev/null
  -w "%{http_code}"
)

if [[ -n "${ELASTICSEARCH_API_KEY:-}" ]]; then
  curl_args+=(-H "Authorization: ApiKey ${ELASTICSEARCH_API_KEY}")
elif [[ -n "${ELASTICSEARCH_USERNAME:-}" && -n "${ELASTICSEARCH_PASSWORD:-}" ]]; then
  curl_args+=(-u "${ELASTICSEARCH_USERNAME}:${ELASTICSEARCH_PASSWORD}")
fi

http_code=$(curl "${curl_args[@]}" "${URL}" 2>/dev/null || echo "000")

if [[ "${http_code}" =~ ^2[0-9][0-9]$ ]]; then
  echo "1"
else
  echo "0"
fi
exit 0
