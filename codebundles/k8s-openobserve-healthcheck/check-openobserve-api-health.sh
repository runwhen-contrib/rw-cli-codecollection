#!/usr/bin/env bash
set -uo pipefail
# -----------------------------------------------------------------------------
# Checks OpenObserve API health: resolves the admin credentials and the base
# URL (auto port-forward to the Service when OPENOBSERVE_BASE_URL is empty) and
# GETs the health endpoint(s). Flags non-200 responses and authentication
# failures.
#
# Health endpoint candidates (probed in order, first 200 wins):
#   /api/{org}/health   (OpenObserve <= v0.x era)
#   /healthz            (modern OpenObserve, root-level, may not need auth)
#   /health             (generic fallback)
# Also probes organisation status endpoints for context (not mandatory).
#
# Required env: CONTEXT, NAMESPACE
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_portforward_helper.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_openobserve_api_common.sh"

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

OUTPUT_FILE="${OUTPUT_FILE:-openobserve_api_health_issues.json}"
issues_json='[]'

ensure_openobserve_base_url || {
  echo "Result: Could not establish an API base URL for OpenObserve."
  issues_json=$(echo "$issues_json" | jq \
    --arg title "OpenObserve API base URL unavailable for namespace \`${NAMESPACE}\`" \
    --arg details "OPENOBSERVE_BASE_URL is empty and the automatic kubectl port-forward could not be established (Service not found or port-forward failed)." \
    --argjson severity 4 \
    --arg next_steps "Confirm the OpenObserve Service exists in NAMESPACE (name containing 'openobserve'), set OPENOBSERVE_SERVICE_NAME explicitly, or provide OPENOBSERVE_BASE_URL." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": $severity,
       "next_steps": $next_steps
     }]')
  echo "$issues_json" | jq . >"$OUTPUT_FILE"
  cat "$OUTPUT_FILE"
  exit 0
}

load_openobserve_credentials || true
BASE_URL="${OPENOBSERVE_BASE_URL%/}"
ORG="${OPENOBSERVE_ORGANIZATION:-default}"
echo "OPENOBSERVE_BASE_URL=${BASE_URL} organization=${ORG}"
if openobserve_creds_present; then
  echo "Credentials: resolved (source cached/file)."
else
  echo "Credentials: NOT resolved - API will likely return HTTP 401."
fi

# --- Primary health probe ---------------------------------------------------
probe_paths=("/api/${ORG}/health" "/healthz" "/health")
http_code="000"
last_path=""
last_body=""
for path in "${probe_paths[@]}"; do
  out=$(openobserve_api_get "$path")
  code="${out%%$'\t'*}"
  body="${out#*$'\t'}"
  echo "GET ${BASE_URL}${path} -> HTTP ${code}"
  if [[ "$code" == "200" ]]; then
    http_code="200"
    last_path="$path"
    last_body="$body"
    break
  fi
  # a 401 means the endpoint exists but authentication failed; keep probing to
  # find one that works but remember the auth failure.
  if [[ "$code" == "401" ]]; then
    http_code="401"
    last_path="$path"
    last_body="$body"
  fi
  last_code="$code"
  last_path="$path"
  last_body="$body"
done

if [[ "$http_code" != "200" ]]; then
  base_err="GET ${BASE_URL}${last_path} returned HTTP ${http_code}."
  echo "Result: OpenObserve API health check FAILED (HTTP ${http_code})."
  if [[ "$http_code" == "401" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "OpenObserve API authentication failed for \`${BASE_URL}\`" \
      --arg details "OpenObserve API returned HTTP 401 (Unauthorized). Credentials could not be validated. ${base_err}" \
      --argjson severity 3 \
      --arg next_steps "Resolve the admin credentials (openobserve_credentials secret, OPENOBSERVE_CREDENTIAL_SECRET_NAME, or ensure ROOT_USER_EMAIL/ROOT_USER_PASSWORD are readable from the workload environment) and re-run." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": $severity,
         "next_steps": $next_steps
       }]')
  else
    issues_json=$(echo "$issues_json" | jq \
      --arg title "OpenObserve API health endpoint unreachable for \`${BASE_URL}\`" \
      --arg details "Expected HTTP 200 from the OpenObserve health endpoint. Got HTTP ${http_code}. Response (truncated): $(echo "$last_body" | head -c 400)" \
      --argjson severity 4 \
      --arg next_steps "Confirm the process is listening on the port, OPENOBSERVE_BASE_URL/svc port-forward is correct, and the API pod is reachable from the runner." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": $severity,
         "next_steps": $next_steps
       }]')
  fi
else
  echo "Result: OpenObserve API health check PASSED (HTTP 200 from ${last_path})."
fi

# --- Optional status probe (informational) ----------------------------------
status_code="000"
for path in "/api/${ORG}/status" "/node/status"; do
  out=$(openobserve_api_get "$path")
  code="${out%%$'\t'*}"
  echo "GET ${BASE_URL}${path} -> HTTP ${code}"
  if [[ "$code" == "200" ]]; then
    status_code="200"
    break
  fi
  if [[ "$code" == "401" && "$http_code" == "200" ]]; then
    echo "Note: Status endpoint required auth which could not be verified; this is informational only."
  fi
done

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "OpenObserve API health check complete. Issues written to $OUTPUT_FILE"
cat "$OUTPUT_FILE"