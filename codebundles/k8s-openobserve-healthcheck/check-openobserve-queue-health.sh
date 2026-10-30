#!/usr/bin/env bash
set -uo pipefail
# -----------------------------------------------------------------------------
# Checks OpenObserve ingestion queue health: queries the queues endpoint and
# flags memory/disk queue key growth that signals ingestion backing up.
#
# Endpoint candidates (probed in order):
#   /api/{org}/queues                      (OpenObserve <= v0.x era)
#   /api/{org}/internal_metrics/queues     (fallback)
#
# Raised when total (mem + disk) queue keys exceed INGESTION_QUEUE_KEY_THRESHOLD.
#
# Required env: CONTEXT, NAMESPACE
# Optional: INGESTION_QUEUE_KEY_THRESHOLD (default 100000)
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_portforward_helper.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_openobserve_api_common.sh"

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

OUTPUT_FILE="${OUTPUT_FILE:-openobserve_queue_issues.json}"
issues_json='[]'
THRESHOLD="${INGESTION_QUEUE_KEY_THRESHOLD:-100000}"

ensure_openobserve_base_url || {
  echo "Result: Could not establish an API base URL for OpenObserve."
  issues_json=$(echo "$issues_json" | jq \
    --arg title "OpenObserve API base URL unavailable for namespace \`${NAMESPACE}\`" \
    --arg details "OPENOBSERVE_BASE_URL is empty and the automatic kubectl port-forward could not be established for the ingestion queue check." \
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

echo "--- OpenObserve ingestion queue health via API (${BASE_URL}/api/${ORG}/... ) ---"

http_code="000"
payload=""
last_path=""
for path in "/api/${ORG}/queues" "/api/${ORG}/internal_metrics/queues"; do
  out=$(openobserve_api_get "$path")
  code="${out%%$'\t'*}"
  body="${out#*$'\t'}"
  last_path="$path"
  echo "GET ${BASE_URL}${path} -> HTTP ${code}"
  if [[ "$code" == "200" ]]; then
    http_code="200"
    payload="$body"
    break
  fi
  http_code="$code"
  payload="$body"
done

if [[ "$http_code" != "200" ]]; then
  if [[ "$http_code" == "401" ]]; then
    echo "Result: queues endpoint returned HTTP 401 - authentication failed."
    issues_json=$(echo "$issues_json" | jq \
      --arg title "OpenObserve API authentication failed for ingestion queues" \
      --arg details "GET ${BASE_URL}${last_path} returned HTTP 401. Admin credentials could not be validated." \
      --argjson severity 3 \
      --arg next_steps "Resolve the admin credentials and re-run." \
      '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
  else
    echo "Result: queues endpoint not available in this OpenObserve version (HTTP ${http_code}); ingestion queue check skipped."
  fi
  echo "$issues_json" | jq . >"$OUTPUT_FILE"
  cat "$OUTPUT_FILE"
  exit 0
fi

# --- Defensive parsing -------------------------------------------------------
# Expected shape variants:
#   {"mem_queue": {"key": N, ...}, "disk_queue": {...}}   (map of queue keys)
#   {"mem_queue": N, "disk_queue": N}                     (flat key-count payload)
#   {"queues": {"mem_queue": {...}, "disk_queue": {...}}}
mem_keys=$(echo "$payload" | jq -r '(.mem_queue // .queues.mem_queue // .data.mem_queue // {}) as $q | if ($q | type) == "number" then $q else ($q | length) end' 2>/dev/null | awk '{print int($1)}')
disk_keys=$(echo "$payload" | jq -r '(.disk_queue // .queues.disk_queue // .data.disk_queue // {}) as $q | if ($q | type) == "number" then $q else ($q | length) end' 2>/dev/null | awk '{print int($1)}')

mem_keys="${mem_keys:-0}"
disk_keys="${disk_keys:-0}"
total=$(( mem_keys + disk_keys ))
echo "Parsed queue keys: mem=${mem_keys} disk=${disk_keys} total=${total} (threshold: ${THRESHOLD})"

if [[ "$total" -gt "$THRESHOLD" ]]; then
  echo "Result: ingestion queue total keys (${total}) exceed threshold (${THRESHOLD})."
  issues_json=$(echo "$issues_json" | jq \
    --arg title "OpenObserve ingestion queue backing up (${total} keys)" \
    --arg details "The queues endpoint reports ${total} total queue keys (mem=${mem_keys}, disk=${disk_keys}), above the threshold of ${THRESHOLD}. Ingestion may be delayed or data may be dropped." \
    --argjson severity 2 \
    --arg next_steps "Investigate ingestion throughput vs processing capacity, disk write speed, and whether WAL files are growing. Consider scaling ingestion nodes or restarting queue worker tasks." \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
else
  echo "Result: ingestion queues are within threshold."
fi

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "OpenObserve ingestion queue check complete. Issues written to $OUTPUT_FILE"
cat "$OUTPUT_FILE"