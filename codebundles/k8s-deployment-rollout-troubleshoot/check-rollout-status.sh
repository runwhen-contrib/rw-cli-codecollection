#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS: CONTEXT, NAMESPACE, DEPLOYMENT_NAME
# OPTIONAL: KUBERNETES_DISTRIBUTION_BINARY, ROLLOUT_STATUS_TIMEOUT
# Outputs issues to check_rollout_status.json
# -----------------------------------------------------------------------------

: "${KUBERNETES_DISTRIBUTION_BINARY:=kubectl}"
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${DEPLOYMENT_NAME:?Must set DEPLOYMENT_NAME}"
: "${ROLLOUT_STATUS_TIMEOUT:=30}"

OUTPUT_FILE="check_rollout_status.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=k8s-rollout-helpers.sh
source "${SCRIPT_DIR}/k8s-rollout-helpers.sh"

init_issues_json

echo "Checking rollout status for deployment ${DEPLOYMENT_NAME} in namespace ${NAMESPACE}"

if ! fetch_deployment_json; then
    write_issues "$OUTPUT_FILE"
    exit 0
fi

replicas=$(echo "$DEPLOYMENT_JSON" | jq '.status.replicas // 0')
updated_replicas=$(echo "$DEPLOYMENT_JSON" | jq '.status.updatedReplicas // 0')
available_replicas=$(echo "$DEPLOYMENT_JSON" | jq '.status.availableReplicas // 0')
ready_replicas=$(echo "$DEPLOYMENT_JSON" | jq '.status.readyReplicas // 0')
desired_replicas=$(echo "$DEPLOYMENT_JSON" | jq '.spec.replicas // 0')
paused=$(echo "$DEPLOYMENT_JSON" | jq -r '.spec.paused // false')

progressing=$(echo "$DEPLOYMENT_JSON" | jq '.status.conditions[]? | select(.type=="Progressing")')
progressing_status=$(echo "$progressing" | jq -r '.status // "Unknown"')
progressing_reason=$(echo "$progressing" | jq -r '.reason // "Unknown"')
progressing_message=$(echo "$progressing" | jq -r '.message // ""')

available_condition=$(echo "$DEPLOYMENT_JSON" | jq '.status.conditions[]? | select(.type=="Available")')
available_status=$(echo "$available_condition" | jq -r '.status // "Unknown"')

echo "Deployment status: replicas=${replicas}, updated=${updated_replicas}, available=${available_replicas}, ready=${ready_replicas}, desired=${desired_replicas}"
echo "Progressing: status=${progressing_status}, reason=${progressing_reason}, message=${progressing_message}"

if [[ "$paused" == "true" ]]; then
    add_issue "3" \
        "Deployment \`${DEPLOYMENT_NAME}\` Rollout is Paused in Namespace \`${NAMESPACE}\`" \
        "spec.paused is true. No rollout progress will occur until the deployment is resumed." \
        "Resume the deployment rollout or investigate why it was paused. Run k8s-deployment-ops Rollback Deployment if a bad revision was paused mid-rollout."
fi

if [[ "$progressing_reason" == "ProgressDeadlineExceeded" ]]; then
    add_issue "2" \
        "Progress Deadline Exceeded for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
        "Progressing condition reason is ProgressDeadlineExceeded. Message: ${progressing_message}. Replica counts: updated=${updated_replicas}/${replicas}, available=${available_replicas}, ready=${ready_replicas}." \
        "Inspect New ReplicaSet Pod Failures for \`${DEPLOYMENT_NAME}\`. Check Rollout Strategy Configuration. Consider Rollback Deployment in k8s-deployment-ops."
fi

if [[ "$progressing_status" == "False" && "$progressing_reason" != "NewReplicaSetAvailable" ]]; then
    add_issue "2" \
        "Deployment \`${DEPLOYMENT_NAME}\` Progressing Condition is False in Namespace \`${NAMESPACE}\`" \
        "Progressing condition status=False, reason=${progressing_reason}, message=${progressing_message}." \
        "Compare Deployment ReplicaSets During Rollout. Detect Rollout Blocking Events. Inspect New ReplicaSet Pod Failures."
fi

if [[ "$updated_replicas" -lt "$replicas" ]]; then
    add_issue "2" \
        "Deployment \`${DEPLOYMENT_NAME}\` Has Outdated ReplicaSet Pods During Rollout in Namespace \`${NAMESPACE}\`" \
        "updatedReplicas (${updated_replicas}) is less than total replicas (${replicas}). Rollout has not fully shifted pods to the new revision." \
        "Compare Deployment ReplicaSets During Rollout. Check PodDisruptionBudget Impact on Rollout. Check Stuck Terminating Pods Blocking Rollout."
fi

if [[ "$available_replicas" -lt "$updated_replicas" || "$ready_replicas" -lt "$updated_replicas" ]]; then
    add_issue "2" \
        "Deployment \`${DEPLOYMENT_NAME}\` New Revision Pods Not Ready in Namespace \`${NAMESPACE}\`" \
        "New revision pods are not fully available/ready: updated=${updated_replicas}, available=${available_replicas}, ready=${ready_replicas}." \
        "Inspect New ReplicaSet Pod Failures for \`${DEPLOYMENT_NAME}\`. Run k8s-app-troubleshoot if pods fail readiness after starting."
fi

if [[ "$available_status" == "False" && "$desired_replicas" -gt 0 ]]; then
    add_issue "3" \
        "Deployment \`${DEPLOYMENT_NAME}\` Not Available in Namespace \`${NAMESPACE}\`" \
        "Available condition is False while desired replicas=${desired_replicas}. Rollout may be incomplete or failing." \
        "Check Deployment Rollout Status and Inspect New ReplicaSet Pod Failures."
fi

rollout_sample=$("${K8S_CMD[@]}" rollout status "deployment/${DEPLOYMENT_NAME}" --timeout="${ROLLOUT_STATUS_TIMEOUT}s" 2>&1 || true)
echo "Rollout status sample (timeout ${ROLLOUT_STATUS_TIMEOUT}s):"
echo "$rollout_sample"

if echo "$rollout_sample" | grep -qiE "progress deadline exceeded|timed out waiting"; then
    add_issue "3" \
        "Rollout Status Timeout for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
        "kubectl rollout status did not complete within ${ROLLOUT_STATUS_TIMEOUT}s: ${rollout_sample}" \
        "Increase ROLLOUT_STATUS_TIMEOUT for deeper sampling or run Compare Deployment ReplicaSets During Rollout."
fi

write_issues "$OUTPUT_FILE"
echo "Analysis completed. Results saved to ${OUTPUT_FILE}"
