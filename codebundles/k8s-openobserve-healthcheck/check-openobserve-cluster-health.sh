#!/usr/bin/env bash
set -uo pipefail
# -----------------------------------------------------------------------------
# Checks OpenObserve cluster processing health: queries cluster_info (per-node
# pending compaction jobs) and flags nodes with a compaction backlog above
# threshold, indicating storage lifecycle work is not keeping up.
#
# Endpoint candidates (probed in order):
#   /api/{org}/cluster/info    (modern OpenObserve)
#   /api/{org}/cluster_info    (older OpenObserve)
#
# Required env: CONTEXT, NAMESPACE
# Optional: CLUSTER_PENDING_JOBS_THRESHOLD (default 100)
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_portforward_helper.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_openobserve_api_common.sh"

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

OUTPUT_FILE="${OUTPUT_FILE:-openobserve_cluster_issues.json}"
issues_json='[]'
THRESHOLD="${CLUSTER_PENDING_JOBS_THRESHOLD:-100}"
: >"$OUTPUT_FILE.tmp"

ensure_openobserve_base_url || {
  echo "Result: Could not establish an API base URL for OpenObserve."
  issues_json=$(echo "$issues_json" | jq \
    --arg title "OpenObserve API base URL unavailable for namespace \`${NAMESPACE}\`" \
    --arg details "OPENOBSERVE_BASE_URL is empty and the automatic kubectl port-forward could not be established for the cluster processing check." \
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

echo "--- OpenObserve cluster processing health via API (${BASE_URL}/api/${ORG}/... ) ---"

http_code="000"
payload=""
last_path=""
for path in "/api/${ORG}/cluster/info" "/api/${ORG}/cluster_info"; do
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
    echo "Result: cluster_info endpoint returned HTTP 401 - authentication failed."
    issues_json=$(echo "$issues_json" | jq \
      --arg title "OpenObserve API authentication failed for cluster info" \
      --arg details "GET ${BASE_URL}${last_path} returned HTTP 401. Admin credentials could not be validated." \
      --argjson severity 3 \
      --arg next_steps "Resolve the admin credentials and re-run." \
      '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
  else
    echo "Result: cluster_info endpoint not available in this OpenObserve version (HTTP ${http_code}); cluster compaction check skipped."
  fi
  echo "$issues_json" | jq . >"$OUTPUT_FILE"
  cat "$OUTPUT_FILE"
  exit 0
fi

# --- Defensive parsing -------------------------------------------------------
# Expected shape: {"regions": {"<region>": {"<node>": {"pending_jobs": N}}}}
node_summary=$(echo "$payload" | jq -c '[.regions // .data.regions // {} | to_entries[] | {region: .key, nodes: .value}]' 2>/dev/null || echo "[]")
echo "Cluster info nodes:"
echo "$node_summary" | jq -c '.[]' 2>/dev/null | while IFS= read -r region; do
  region_name=$(echo "$region" | jq -r '.region // "unknown"')
  echo "$region" | jq -c --argjson thresh "$THRESHOLD" --arg region_name "$region_name" \
    '.nodes | to_entries[] | {node: .key, region: $region_name, pending_jobs: (.value.pending_jobs // 0)}' 2>/dev/null | while IFS= read -r over; do
    node=$(echo "$over" | jq -r '.node')
    reg=$(echo "$over" | jq -r '.region')
    pj=$(echo "$over" | jq -r '.pending_jobs')
    echo "  Node ${node} (region ${reg}): pending_jobs=${pj}"
    if [[ "$pj" -gt "$THRESHOLD" ]]; then
      echo "Result: Node ${node} has a pending compaction backlog (${pj} jobs)."
      jq -n --arg node "$node" --arg reg "$reg" --arg pj "$pj" \
        --arg title "OpenObserve node \`${node}\` has a pending compaction backlog (${pj} jobs)" \
        --arg details "cluster_info reports ${pj} pending compaction jobs on node ${node} (region ${reg}), above the threshold of ${THRESHOLD}. Compaction/parquet lifecycle work is not keeping up." \
        --argjson severity 2 \
        --arg next_steps "Check OpenObserve compaction scheduler health and CPU/IO on the node. Increase compaction resources or investigate why jobs are queuing." \
        '{title: $title, details: $details, severity: $severity, next_steps: $next_steps}' >>"$OUTPUT_FILE.tmp"
    fi
  done
done

if [[ -s "$OUTPUT_FILE.tmp" ]]; then
  issues_json=$(jq -s . "$OUTPUT_FILE.tmp" 2>/dev/null || echo '[]')
  rm -f "$OUTPUT_FILE.tmp"
else
  issues_json='[]'
  rm -f "$OUTPUT_FILE.tmp"
fi

if [[ "$(echo "$issues_json" | jq -r 'length')" -eq 0 ]]; then
  echo "Result: No pending compaction backlog above threshold (${THRESHOLD})."
fi

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "OpenObserve cluster processing check complete. Issues written to $OUTPUT_FILE"
cat "$OUTPUT_FILE"