#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS: CONTEXT, NAMESPACE, DEPLOYMENT_NAME
# Outputs issues to inspect_new_replicaset_pod_failures.json
# -----------------------------------------------------------------------------

: "${KUBERNETES_DISTRIBUTION_BINARY:=kubectl}"
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${DEPLOYMENT_NAME:?Must set DEPLOYMENT_NAME}"

OUTPUT_FILE="inspect_new_replicaset_pod_failures.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=k8s-rollout-helpers.sh
source "${SCRIPT_DIR}/k8s-rollout-helpers.sh"

init_issues_json

echo "Inspecting new ReplicaSet pod failures for deployment ${DEPLOYMENT_NAME}"

if ! fetch_deployment_json; then
    write_issues "$OUTPUT_FILE"
    exit 0
fi

fetch_deployment_replicasets_json
LATEST_RS=$(get_latest_replicaset_name)

if [[ -z "$LATEST_RS" ]]; then
    add_issue "3" \
        "No Latest ReplicaSet for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
        "Cannot inspect new ReplicaSet pods without a ReplicaSet." \
        "Verify deployment configuration and events."
    write_issues "$OUTPUT_FILE"
    exit 0
fi

get_latest_replicaset_pods_json "$LATEST_RS"
pod_count=$(echo "$PODS_JSON" | jq '.items | length')
echo "Latest ReplicaSet ${LATEST_RS} has ${pod_count} pod(s)"

blocking_states=("Pending" "CrashLoopBackOff" "ImagePullBackOff" "ErrImagePull" "CreateContainerConfigError" "CreateContainerError" "RunContainerError" "InvalidImageName")

for state in "${blocking_states[@]}"; do
    matches=$(echo "$PODS_JSON" | jq --arg state "$state" \
        '[.items[] | select(.status.phase==$state or (.status.containerStatuses[]? | .state.waiting.reason==$state) or (.status.initContainerStatuses[]? | .state.waiting.reason==$state)) | .metadata.name]')
    count=$(echo "$matches" | jq 'length')
    if [[ "$count" -gt 0 ]]; then
        names=$(echo "$matches" | jq -r '.[]' | tr '\n' ', ')
        details=""
        while IFS= read -r pod_name; do
            [[ -z "$pod_name" ]] && continue
            pod_detail=$(echo "$PODS_JSON" | jq --arg pod "$pod_name" \
                '.items[] | select(.metadata.name==$pod) | {phase: .status.phase, conditions: .status.conditions, containerStatuses: .status.containerStatuses}')
            details="${details}Pod ${pod_name}: ${pod_detail}\n"
        done < <(echo "$matches" | jq -r '.[]')

        severity="2"
        next_steps="Detect Rollout Blocking Events for \`${DEPLOYMENT_NAME}\`."
        if [[ "$state" == "ImagePullBackOff" || "$state" == "ErrImagePull" || "$state" == "InvalidImageName" ]]; then
            next_steps="Verify container image name, tag, and registry credentials. Check Rollout History for recent image changes."
        elif [[ "$state" == "CrashLoopBackOff" ]]; then
            next_steps="Run k8s-app-troubleshoot for application logs. Consider Rollback Deployment in k8s-deployment-ops."
        elif [[ "$state" == "Pending" ]]; then
            next_steps="Detect Rollout Blocking Events for scheduling failures. Check cluster resource quotas and node capacity."
        elif [[ "$state" == "CreateContainerConfigError" ]]; then
            next_steps="Verify ConfigMaps, Secrets, and env references in the latest deployment revision."
        fi

        add_issue "$severity" \
            "New ReplicaSet Pods in ${state} for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
            "${count} pod(s) on latest RS ${LATEST_RS} in ${state}: ${names}. ${details}" \
            "${next_steps}"
    fi
done

# Readiness failures after start
not_ready=$(echo "$PODS_JSON" | jq \
    '[.items[] | select(.status.phase=="Running") | select(.status.conditions[]? | select(.type=="Ready" and .status=="False")) | .metadata.name]')
not_ready_count=$(echo "$not_ready" | jq 'length')
if [[ "$not_ready_count" -gt 0 ]]; then
    names=$(echo "$not_ready" | jq -r '.[]' | tr '\n' ', ')
    add_issue "2" \
        "New ReplicaSet Pods Failing Readiness for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
        "${not_ready_count} running pod(s) on latest RS ${LATEST_RS} are not Ready: ${names}." \
        "Run k8s-deployment-healthcheck probe validation tasks. Run k8s-app-troubleshoot for deeper log analysis."
fi

write_issues "$OUTPUT_FILE"
echo "Analysis completed. Results saved to ${OUTPUT_FILE}"
