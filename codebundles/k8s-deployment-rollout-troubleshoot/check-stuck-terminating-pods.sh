#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS: CONTEXT, NAMESPACE, DEPLOYMENT_NAME
# OPTIONAL: STUCK_TERMINATING_THRESHOLD (default 5 minutes)
# Outputs issues to check_stuck_terminating_pods.json
# -----------------------------------------------------------------------------

: "${KUBERNETES_DISTRIBUTION_BINARY:=kubectl}"
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${DEPLOYMENT_NAME:?Must set DEPLOYMENT_NAME}"
: "${STUCK_TERMINATING_THRESHOLD:=5}"

OUTPUT_FILE="check_stuck_terminating_pods.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=k8s-rollout-helpers.sh
source "${SCRIPT_DIR}/k8s-rollout-helpers.sh"

init_issues_json

echo "Checking stuck terminating pods for deployment ${DEPLOYMENT_NAME} (threshold: ${STUCK_TERMINATING_THRESHOLD}m)"

if ! fetch_deployment_json; then
    write_issues "$OUTPUT_FILE"
    exit 0
fi

get_deployment_pods_json
threshold_seconds=$(( STUCK_TERMINATING_THRESHOLD * 60 ))
now_epoch=$(date -u +%s)

terminating_pods=$(echo "$PODS_JSON" | jq '[.items[] | select(.metadata.deletionTimestamp != null)]')
terminating_count=$(echo "$terminating_pods" | jq 'length')

echo "Found ${terminating_count} pod(s) in Terminating state"

if [[ "$terminating_count" -eq 0 ]]; then
    write_issues "$OUTPUT_FILE"
    echo "No terminating pods found."
    exit 0
fi

stuck_pods=()
while IFS= read -r pod_line; do
    [[ -z "$pod_line" ]] && continue
    pod_name=$(echo "$pod_line" | jq -r '.metadata.name')
    deletion_ts=$(echo "$pod_line" | jq -r '.metadata.deletionTimestamp')
    finalizers=$(echo "$pod_line" | jq -r '.metadata.finalizers // [] | join(", ")')
    node=$(echo "$pod_line" | jq -r '.spec.nodeName // "unscheduled"')
    grace=$(echo "$pod_line" | jq -r '.spec.terminationGracePeriodSeconds // 30')

    deletion_epoch=$(date -d "$deletion_ts" +%s 2>/dev/null || echo "$now_epoch")
    age_seconds=$(( now_epoch - deletion_epoch ))

    echo "Pod ${pod_name}: terminating for ${age_seconds}s, node=${node}, finalizers=[${finalizers}], grace=${grace}s"

    if [[ "$age_seconds" -ge "$threshold_seconds" ]]; then
        stuck_pods+=("${pod_name} (age=${age_seconds}s, node=${node}, finalizers=[${finalizers}])")
    fi
done < <(echo "$terminating_pods" | jq -c '.[]')

if [[ ${#stuck_pods[@]} -gt 0 ]]; then
    stuck_list=$(printf '%s; ' "${stuck_pods[@]}")
    add_issue "2" \
        "Stuck Terminating Pods Block Rollout for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
        "${#stuck_pods[@]} pod(s) exceeded ${STUCK_TERMINATING_THRESHOLD}m terminating threshold: ${stuck_list}" \
        "Force Delete Pods in k8s-deployment-ops if safe. Check node connectivity and finalizers. Verify kubelet and CNI on affected nodes."
fi

if [[ "$terminating_count" -gt 0 && ${#stuck_pods[@]} -eq 0 ]]; then
    add_issue "3" \
        "Pods Terminating During Rollout for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
        "${terminating_count} pod(s) are terminating but within ${STUCK_TERMINATING_THRESHOLD}m threshold. Monitor for completion." \
        "Re-run this check if rollout remains stalled. Compare Deployment ReplicaSets During Rollout."
fi

write_issues "$OUTPUT_FILE"
echo "Analysis completed. Results saved to ${OUTPUT_FILE}"
