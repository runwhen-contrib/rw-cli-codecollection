#!/usr/bin/env bash
set -euo pipefail
set -x
# Discovers SeaweedFS workloads, services, and PVCs in the namespace.
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

OUTPUT_FILE="list_seaweedfs_resources_issues.json"
# shellcheck disable=SC1091
source seaweedfs-lib.sh

print_report() {
  { set +x; } 2>/dev/null || true
  echo
  echo "=== SeaweedFS component map (namespace ${NAMESPACE}, context ${CONTEXT}) ==="
  if [[ -f "$COMPONENT_MAP_FILE" ]]; then
    jq '.' "$COMPONENT_MAP_FILE"
  fi
  local ic
  ic=$(jq 'length' "$OUTPUT_FILE" 2>/dev/null || echo 0)
  echo "=== Findings (${ic}) ==="
  if [[ "$ic" -eq 0 ]]; then
    echo "  Discovery completed without blocking issues."
  else
    jq -r '.[] | "  - [sev=\(.severity)] \(.title)"' "$OUTPUT_FILE"
  fi
}
trap print_report EXIT

if ! "${KUBECTL}" get ns "${NAMESPACE}" --context "${CONTEXT}" -o name &>/dev/null; then
  swf_add_issue \
    "Namespace \`${NAMESPACE}\` not accessible in context \`${CONTEXT}\`" \
    "kubectl cannot read the target namespace." \
    4 \
    "Verify NAMESPACE and kubeconfig RBAC for namespace read access."
  swf_write_issues "$OUTPUT_FILE"
  exit 0
fi

map_json=$(swf_discover_components)
echo "$map_json" >"$COMPONENT_MAP_FILE"

sts_count=$(echo "$map_json" | jq '.statefulsets | length')
dep_count=$(echo "$map_json" | jq '.deployments | length')
if [[ "$sts_count" -eq 0 && "$dep_count" -eq 0 ]]; then
  swf_add_issue \
    "No SeaweedFS workloads found in namespace \`${NAMESPACE}\`" \
    "No StatefulSets or Deployments matched SeaweedFS labels or name patterns." \
    3 \
    "Confirm SeaweedFS is installed. Set SEAWEEDFS_RELEASE_NAME if using non-standard labels."
fi

for required in master volume filer; do
  found=$(echo "$map_json" | jq --arg c "$required" '[.statefulsets[], .deployments[]] | map(select(.component == $c or (.name | test($c; "i")))) | length')
  if [[ "$found" -eq 0 ]]; then
    swf_add_issue \
      "Missing SeaweedFS \`${required}\` component in namespace \`${NAMESPACE}\`" \
      "Expected a workload for component ${required} but none was discovered." \
      4 \
      "Check Helm values for ${required}.enabled and label selectors app.kubernetes.io/component=${required}."
  fi
done

while IFS= read -r wl; do
  [[ -z "$wl" ]] && continue
  name=$(echo "$wl" | jq -r '.name')
  want=$(echo "$wl" | jq -r '.replicas')
  ready=$(echo "$wl" | jq -r '.ready')
  if [[ "$want" =~ ^[0-9]+$ ]] && [[ "$want" -gt 0 ]] && [[ "$ready" == "0" ]]; then
    swf_add_issue \
      "SeaweedFS workload \`${name}\` has zero ready replicas" \
      "desired=${want}, ready=${ready}" \
      3 \
      "Inspect pods for ${name}: kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=seaweedfs --context ${CONTEXT}"
  fi
done < <(echo "$map_json" | jq -c '.statefulsets[], .deployments[]')

swf_write_issues "$OUTPUT_FILE"
