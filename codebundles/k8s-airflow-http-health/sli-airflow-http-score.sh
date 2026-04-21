#!/usr/bin/env bash
set -uo pipefail
# -----------------------------------------------------------------------------
# Single-line JSON for sli.robot: webserver_health, api_reachability, k8s_service.
# Diagnostics to stderr; port-forward banner redirected to stderr.
# -----------------------------------------------------------------------------
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${AIRFLOW_WEBSERVER_SERVICE_NAME:?Must set AIRFLOW_WEBSERVER_SERVICE_NAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_airflow_http_portforward_helper.sh"
ensure_airflow_proxy_base_url 1>&2 || true

BASE_URL="${PROXY_BASE_URL%/}"
MAX_TIME="${CURL_MAX_TIME:-15}"
KBIN="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"

# --- webserver /health ---
ws_score=0
tmpf=$(mktemp)
rc=$(curl -sS --max-time "$MAX_TIME" -o "$tmpf" -w "%{http_code}" "${BASE_URL}/health" 2>/dev/null || echo "000")
body=$(cat "$tmpf" || true)
rm -f "$tmpf"
if [[ "$rc" == "200" ]] && echo "$body" | jq -e . >/dev/null 2>&1; then
  mb=$(echo "$body" | jq -r '.metadatabase.status // empty')
  if [[ -z "$mb" || "$mb" == "null" ]]; then
    ws_score=1
  elif [[ "$mb" == "healthy" ]]; then
    ws_score=1
  else
    ws_score=0
  fi
fi

# --- API quick probe (no auth in SLI) ---
api_score=0
for path in "/api/v1/health" "/api/v1/version"; do
  c=$(curl -sS --max-time "$MAX_TIME" -o /dev/null -w "%{http_code}" "${BASE_URL}${path}" 2>/dev/null || echo "000")
  if [[ "$c" == "200" || "$c" == "401" || "$c" == "403" ]]; then
    api_score=1
    break
  fi
done

# --- Service exists ---
k8s_score=0
if command -v "$KBIN" &>/dev/null; then
  if "$KBIN" get svc "$AIRFLOW_WEBSERVER_SERVICE_NAME" -n "$NAMESPACE" --context "$CONTEXT" --request-timeout=8s &>/dev/null; then
    k8s_score=1
  fi
fi

jq -cn --argjson w "$ws_score" --argjson a "$api_score" --argjson k "$k8s_score" \
  '{webserver_health:$w, api_reachability:$a, kubernetes_service:$k}'
