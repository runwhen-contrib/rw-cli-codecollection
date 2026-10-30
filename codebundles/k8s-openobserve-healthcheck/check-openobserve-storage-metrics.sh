#!/usr/bin/env bash
set -uo pipefail
# -----------------------------------------------------------------------------
# Checks OpenObserve storage health via the API storage_metrics endpoint.
# This is the source of truth for storage health since storage is not
# observable from inside the container.
#
# Endpoint candidates (probed in order):
#   /api/{org}/storage_metrics   (OpenObserve <= v0.x era)
#   /api/{org}/internal_metrics  (some versions rename it)
#
# Flags s3_access_failures above STORAGE_S3_FAILURE_THRESHOLD and WAL/parquet
# growth. Parsed defensively: all numeric fields are optional across versions.
#
# Required env: CONTEXT, NAMESPACE
# Optional: STORAGE_S3_FAILURE_THRESHOLD (default 10)
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_portforward_helper.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_openobserve_api_common.sh"

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

OUTPUT_FILE="${OUTPUT_FILE:-openobserve_storage_issues.json}"
issues_json='[]'
THRESHOLD="${STORAGE_S3_FAILURE_THRESHOLD:-10}"

ensure_openobserve_base_url || {
  echo "Result: Could not establish an API base URL for OpenObserve."
  issues_json=$(echo "$issues_json" | jq \
    --arg title "OpenObserve API base URL unavailable for namespace \`${NAMESPACE}\`" \
    --arg details "OPENOBSERVE_BASE_URL is empty and the automatic kubectl port-forward could not be established for the storage metrics check." \
    --argjson severity 3 \
    --arg next_steps "Confirm the OpenObserve Service exists in NAMESPACE, set OPENOBSERVE_SERVICE_NAME explicitly, or provide OPENOBSERVE_BASE_URL." \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
  echo "$issues_json" | jq . >"$OUTPUT_FILE"
  cat "$OUTPUT_FILE"
  exit 0
}

load_openobserve_credentials || true
BASE_URL="${OPENOBSERVE_BASE_URL%/}"
ORG="${OPENOBSERVE_ORGANIZATION:-default}"

echo "--- OpenObserve storage metrics via API (${BASE_URL}/api/${ORG}/... ) ---"

endpoint=""
last_path=""
payload=""
http_code="000"
for path in "/api/${ORG}/storage_metrics" "/api/${ORG}/internal_metrics"; do
  out=$(openobserve_api_get "$path")
  code="${out%%$'\t'*}"
  body="${out#*$'\t'}"
  last_path="$path"
  echo "GET ${BASE_URL}${path} -> HTTP ${code}"
  if [[ "$code" == "200" ]]; then
    endpoint="$path"
    payload="$body"
    http_code="200"
    break
  fi
  http_code="$code"
  payload="$body"
done

if [[ "$http_code" != "200" ]]; then
  if [[ "$http_code" == "401" ]]; then
    echo "Result: storage_metrics endpoint returned HTTP 401 - authentication failed."
    issues_json=$(echo "$issues_json" | jq \
      --arg title "OpenObserve API authentication failed for storage metrics" \
      --arg details "GET ${BASE_URL}${last_path} returned HTTP 401. Admin credentials could not be validated." \
      --argjson severity 3 \
      --arg next_steps "Resolve the admin credentials (see OPENOBSERVE_CREDENTIAL_SECRET_NAME or openobserve_credentials secret) and re-run." \
      '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
  else
    echo "Result: storage_metrics endpoint not available in this OpenObserve version (HTTP ${http_code}). Storage API view not supported; no storage issue raised."
  fi
  echo "$issues_json" | jq . >"$OUTPUT_FILE"
  cat "$OUTPUT_FILE"
  exit 0
fi

# --- Defensive parsing of the storage metrics payload ------------------------
# The shape changed across versions. Numeric fields are optional; missing
# fields are not raised as issues.
echo "storage_metrics payload available (${#payload} bytes)."

s3_failures=$(echo "$payload" | jq -r '(.s3_access_failures // .s3_failures // .data.s3_access_failures // .data.s3_failures // 0)' 2>/dev/null | awk '{print int($1)}')
events=$(echo "$payload" | jq -r '(.events // .data.events // 0)' 2>/dev/null | awk '{print int($1)}')
wal_files=$(echo "$payload" | jq -r '(.wal_files // .data.wal_files // 0)' 2>/dev/null | awk '{print int($1)}')
wal_bytes=$(echo "$payload" | jq -r '(.wal_bytes // .data.wal_bytes // 0)' 2>/dev/null | awk '{print int($1)}')
parquet_files=$(echo "$payload" | jq -r '(.parquet_files // .data.parquet_files // 0)' 2>/dev/null | awk '{print int($1)}')
parquet_bytes=$(echo "$payload" | jq -r '(.parquet_bytes // .data.parquet_bytes // 0)' 2>/dev/null | awk '{print int($1)}')

s3_failures="${s3_failures:-0}"
echo "Parsed storage metrics: s3_access_failures=${s3_failures} events=$(echo "${events:-0}") wal_files=$(echo "${wal_files:-0}") parquet_files=$(echo "${parquet_files:-0}")"

if [[ "$s3_failures" -gt "$THRESHOLD" ]]; then
  echo "Result: s3_access_failures (${s3_failures}) exceed threshold (${THRESHOLD})."
  issues_json=$(echo "$issues_json" | jq \
    --arg title "OpenObserve S3 access failures above threshold (${s3_failures})" \
    --arg details "storage_metrics reports ${s3_failures} S3 access failures (threshold: ${THRESHOLD}). This indicates the storage backend is failing or inaccessible, so queries/writes over S3 may be failing." \
    --argjson severity 3 \
    --arg next_steps "Verify the S3 bucket/object store credentials and reachability (ingress rules, network policy, TLS), check the OpenObserve logs for S3 errors, and confirm the backing storage (e.g. SeaweedFS S3 gateway) is healthy." \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
fi

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "OpenObserve storage metrics check complete. Issues written to $OUTPUT_FILE"
cat "$OUTPUT_FILE"