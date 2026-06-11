#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS: CONTEXT, NAMESPACE, DEPLOYMENT_NAME
# Outputs issues to compare_replicasets_during_rollout.json
# -----------------------------------------------------------------------------

: "${KUBERNETES_DISTRIBUTION_BINARY:=kubectl}"
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${DEPLOYMENT_NAME:?Must set DEPLOYMENT_NAME}"

OUTPUT_FILE="compare_replicasets_during_rollout.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=k8s-rollout-helpers.sh
source "${SCRIPT_DIR}/k8s-rollout-helpers.sh"

init_issues_json

echo "Comparing ReplicaSets for deployment ${DEPLOYMENT_NAME} in namespace ${NAMESPACE}"

if ! fetch_deployment_json; then
    write_issues "$OUTPUT_FILE"
    exit 0
fi

fetch_deployment_replicasets_json
LATEST_RS=$(get_latest_replicaset_name)
rs_count=$(echo "$REPLICASETS_JSON" | jq 'length')

echo "Found ${rs_count} ReplicaSet(s). Latest: ${LATEST_RS:-none}"

if [[ -z "$LATEST_RS" ]]; then
    add_issue "3" \
        "No ReplicaSets Found for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
        "No ReplicaSets are owned by this deployment." \
        "Verify deployment exists and has created a ReplicaSet. Inspect Deployment Warning Events."
    write_issues "$OUTPUT_FILE"
    exit 0
fi

latest_rs_replicas=$(echo "$REPLICASETS_JSON" | jq --arg rs "$LATEST_RS" '.[] | select(.metadata.name==$rs) | .status.replicas // 0')
latest_rs_ready=$(echo "$REPLICASETS_JSON" | jq --arg rs "$LATEST_RS" '.[] | select(.metadata.name==$rs) | .status.readyReplicas // 0')
desired_replicas=$(echo "$DEPLOYMENT_JSON" | jq '.spec.replicas // 0')

get_deployment_pods_json
outdated_pods=$(echo "$PODS_JSON" | jq --arg rs "$LATEST_RS" \
    '[.items[] | select(.metadata.ownerReferences[]? | select(.kind=="ReplicaSet" and .name != $rs)) | .metadata.name] | length')

if [[ "$outdated_pods" -gt 0 ]]; then
    outdated_names=$(echo "$PODS_JSON" | jq -r --arg rs "$LATEST_RS" \
        '.items[] | select(.metadata.ownerReferences[]? | select(.kind=="ReplicaSet" and .name != $rs)) | .metadata.name' | tr '\n' ', ')
    add_issue "2" \
        "Outdated Pods Not on Latest ReplicaSet for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
        "${outdated_pods} pod(s) are owned by older ReplicaSets: ${outdated_names}. Latest RS: ${LATEST_RS}." \
        "Scale Down Stale ReplicaSets in k8s-deployment-ops. Check Stuck Terminating Pods Blocking Rollout."
fi

active_old_rs=()
while IFS= read -r rs_name; do
    [[ -z "$rs_name" || "$rs_name" == "$LATEST_RS" ]] && continue
    rs_replicas=$(echo "$REPLICASETS_JSON" | jq --arg rs "$rs_name" '.[] | select(.metadata.name==$rs) | .status.replicas // 0')
    if [[ "$rs_replicas" -gt 0 ]]; then
        active_old_rs+=("$rs_name (replicas=${rs_replicas})")
    fi
done < <(echo "$REPLICASETS_JSON" | jq -r '.[].metadata.name')

if [[ ${#active_old_rs[@]} -gt 0 ]]; then
    active_list=$(printf '%s; ' "${active_old_rs[@]}")
    updated_replicas=$(echo "$DEPLOYMENT_JSON" | jq '.status.updatedReplicas // 0')
    if [[ "$updated_replicas" -lt "$desired_replicas" ]]; then
        add_issue "2" \
            "Conflicting Active ReplicaSets During Rollout for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
            "Older ReplicaSets still have active replicas during incomplete rollout: ${active_list}. Latest RS ${LATEST_RS} has ${latest_rs_replicas} replicas (${latest_rs_ready} ready)." \
            "Compare rollout strategy maxUnavailable/maxSurge. Check PodDisruptionBudget Impact. Scale Down Stale ReplicaSets after confirming new pods are healthy."
    else
        add_issue "3" \
            "Multiple Active ReplicaSets for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
            "Rollout may still be in progress. Active older ReplicaSets: ${active_list}." \
            "Wait for rollout to complete or inspect blocking events if stalled."
    fi
fi

if [[ "$latest_rs_replicas" -eq 0 && "$desired_replicas" -gt 0 ]]; then
    add_issue "2" \
        "Latest ReplicaSet Has Zero Replicas for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
        "Latest ReplicaSet ${LATEST_RS} has 0 replicas while deployment desired=${desired_replicas}. New revision is not receiving traffic." \
        "Inspect New ReplicaSet Pod Failures. Check Rollout Strategy Configuration and PDB constraints."
fi

if [[ "$latest_rs_ready" -lt "$latest_rs_replicas" ]]; then
    add_issue "2" \
        "Latest ReplicaSet Pods Not Ready for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
        "Latest RS ${LATEST_RS}: ready=${latest_rs_ready}, replicas=${latest_rs_replicas}." \
        "Inspect New ReplicaSet Pod Failures for \`${DEPLOYMENT_NAME}\`. Run k8s-app-troubleshoot for application-level failures."
fi

write_issues "$OUTPUT_FILE"
echo "Analysis completed. Results saved to ${OUTPUT_FILE}"
