#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Shared helper for OpenObserve HTTP API calls.
#
# Provides:
#   load_openobserve_credentials     - loads cached credentials (if any) into
#                                      OPENOBSERVE_USERNAME / OPENOBSERVE_PASSWORD.
#   openobserve_creds_present        - returns 0 when username+password are set.
#   openobserve_api_get <fullpath>   - GETs ${OPENOBSERVE_BASE_URL}<fullpath> with
#                                      optional HTTP Basic auth and echoes
#                                      "HTTP_CODE\t<response body>".
#                                      On failure echoes "000\t".
#
# Uses OPENOBSERVE_API_TIMEOUT (default 25) to bound every curl call.
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_openobserve_credentials_helper.sh"

OPENOBSERVE_ORGANIZATION="${OPENOBSERVE_ORGANIZATION:-default}"
API_TIMEOUT="${OPENOBSERVE_API_TIMEOUT:-25}"

load_openobserve_credentials() {
  local cache="${OPENOBSERVE_CREDENTIALS_CACHE_FILE:-./.openobserve_credentials}"
  if [[ -s "$cache" ]]; then
    OPENOBSERVE_USERNAME=$(sed -n '1p' "$cache")
    OPENOBSERVE_PASSWORD=$(sed -n '2p' "$cache")
    export OPENOBSERVE_USERNAME OPENOBSERVE_PASSWORD
    return 0
  fi
  OPENOBSERVE_USERNAME="${OPENOBSERVE_USERNAME:-}"
  OPENOBSERVE_PASSWORD="${OPENOBSERVE_PASSWORD:-}"
  return 1
}

openobserve_creds_present() {
  [[ -n "${OPENOBSERVE_USERNAME:-}" && -n "${OPENOBSERVE_PASSWORD:-}" ]]
}

# GET ${OPENOBSERVE_BASE_URL}$1 with optional Basic auth.
# Echoes "HTTP_CODE\t<response body>".
openobserve_api_get() {
  local path="$1"
  local base="${OPENOBSERVE_BASE_URL:-}"
  base="${base%/}"
  local url="${base}${path}"
  local tmpf http_code
  tmpf=$(mktemp)
  if openobserve_creds_present; then
    http_code=$(curl -sS --max-time "$API_TIMEOUT" -u "${OPENOBSERVE_USERNAME}:${OPENOBSERVE_PASSWORD}" -o "$tmpf" -w "%{http_code}" "$url" 2>/dev/null || echo "000")
  else
    http_code=$(curl -sS --max-time "$API_TIMEOUT" -o "$tmpf" -w "%{http_code}" "$url" 2>/dev/null || echo "000")
  fi
  printf '%s\t%s' "$http_code" "$(cat "$tmpf" 2>/dev/null || true)"
  rm -f "$tmpf"
}