#!/usr/bin/env bash
set -euo pipefail
set -x
# Confirms filer health and data node registration in master topology.
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

OUTPUT_FILE="component_connectivity_issues.json"
# shellcheck disable=SC1091
source seaweedfs-lib.sh

print_report() {
  { set +x; } 2>/dev/null || true
  echo "=== SeaweedFS component connectivity ==="
  jq -r '.[] | "  - [sev=\(.severity)] \(.title)"' "$OUTPUT_FILE" 2>/dev/null || true
}
trap print_report EXIT

filer_pod=$(swf_find_pod "filer")
if [[ -z "$filer_pod" ]]; then
  swf_add_issue \
    "No running SeaweedFS filer pod in namespace \`${NAMESPACE}\`" \
    "Filer connectivity checks were skipped." \
    3 \
    "Verify filer StatefulSet and app.kubernetes.io/component=filer label."
else
  filer_ok=false
  for path in "/healthz" "/status"; do
    if resp=$(swf_filer_http "$path" 2>/dev/null); then
      if echo "$resp" | grep -qiE 'ok|healthy|running|success|version'; then
        filer_ok=true
        break
      fi
    fi
  done
  if [[ "$filer_ok" != true ]]; then
    swf_add_issue \
      "SeaweedFS filer health endpoint unhealthy in namespace \`${NAMESPACE}\`" \
      "Neither /healthz nor /status returned a healthy response from pod ${filer_pod}." \
      2 \
      "Check filer logs and master address configuration (WEED_CLUSTER_SW_MASTER)."
  fi
fi

if ! dir_status=$(swf_master_http "/dir/status" 2>/dev/null); then
  swf_add_issue \
    "Cannot validate volume server registration: /dir/status failed in \`${NAMESPACE}\`" \
    "Master topology unavailable." \
    2 \
    "Restore master API connectivity."
  swf_write_issues "$OUTPUT_FILE"
  exit 0
fi

# Count data nodes in topology
data_nodes=$(echo "$dir_status" | jq '[.. | objects | select(has("Url") or has("url") or has("PublicUrl") or has("publicUrl")) | (.Url // .url // .PublicUrl // .publicUrl)] | unique | length' 2>/dev/null || echo 0)
volume_pods=$("${KUBECTL}" get pods -n "${NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null \
  | jq '[.items[] | select(.status.phase=="Running") | select(.metadata.labels["app.kubernetes.io/component"]? == "volume" or (.metadata.name | test("volume"; "i")))] | length' || echo 0)

if [[ "$volume_pods" =~ ^[0-9]+$ ]] && [[ "$volume_pods" -gt 0 ]]; then
  if [[ "$data_nodes" =~ ^[0-9]+$ ]] && [[ "$data_nodes" -eq 0 ]]; then
    swf_add_issue \
      "SeaweedFS volume pods run but master topology lists zero data nodes in \`${NAMESPACE}\`" \
      "Running volume pods=${volume_pods}, topology nodes=${data_nodes}" \
      2 \
      "Verify volume servers can reach master on port ${MASTER_PORT}; check weed shell logs."
  elif [[ "$data_nodes" =~ ^[0-9]+$ ]] && [[ "$data_nodes" -lt "$volume_pods" ]]; then
    swf_add_issue \
      "SeaweedFS topology missing registered volume servers in \`${NAMESPACE}\`" \
      "Running volume pods=${volume_pods}, registered topology nodes=${data_nodes}" \
      3 \
      "Restart unregistered volume pods and inspect heartbeat errors."
  fi
fi

# Stale / unreachable hints from ec shards or failed nodes (best-effort)
stale=$(echo "$dir_status" | jq '[.. | strings | select(test("stale|unreachable|offline"; "i"))] | length' 2>/dev/null || echo 0)
if [[ "$stale" =~ ^[0-9]+$ ]] && [[ "$stale" -gt 0 ]]; then
  swf_add_issue \
    "SeaweedFS topology contains stale or unreachable node hints in \`${NAMESPACE}\`" \
    "Found ${stale} stale/unreachable markers in /dir/status payload." \
    3 \
    "Compare topology data nodes with Running volume pods and decommission dead nodes."
fi

swf_write_issues "$OUTPUT_FILE"
