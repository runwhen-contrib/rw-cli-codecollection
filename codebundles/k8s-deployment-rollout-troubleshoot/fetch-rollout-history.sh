#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS: CONTEXT, NAMESPACE, DEPLOYMENT_NAME
# Outputs issues to fetch_rollout_history.json
# -----------------------------------------------------------------------------

: "${KUBERNETES_DISTRIBUTION_BINARY:=kubectl}"
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${DEPLOYMENT_NAME:?Must set DEPLOYMENT_NAME}"

OUTPUT_FILE="fetch_rollout_history.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=k8s-rollout-helpers.sh
source "${SCRIPT_DIR}/k8s-rollout-helpers.sh"

init_issues_json

echo "Fetching rollout history for deployment ${DEPLOYMENT_NAME}"

if ! fetch_deployment_json; then
    write_issues "$OUTPUT_FILE"
    exit 0
fi

current_revision=$(echo "$DEPLOYMENT_JSON" | jq -r '.metadata.annotations["deployment.kubernetes.io/revision"] // "unknown"')
echo "Current revision: ${current_revision}"

history_output=$("${K8S_CMD[@]}" rollout history "deployment/${DEPLOYMENT_NAME}" 2>&1 || true)
echo "Rollout history:"
echo "$history_output"

fetch_deployment_replicasets_json

revision_summary=$(echo "$REPLICASETS_JSON" | jq -r \
    'sort_by(.metadata.creationTimestamp) | reverse | .[:5][] |
     "RS \(.metadata.name) rev=\(.metadata.annotations["deployment.kubernetes.io/revision"] // "?") replicas=\(.status.replicas // 0) image=\(.spec.template.spec.containers[0].image // "unknown")"' | tr '\n' '; ')

if [[ -z "$revision_summary" ]]; then
    add_issue "4" \
        "No Rollout Revision History for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
        "No ReplicaSets found to summarize revision history." \
        "Verify deployment has been updated at least once."
    write_issues "$OUTPUT_FILE"
    exit 0
fi

echo "Recent revisions: ${revision_summary}"

# Compare latest two revisions for meaningful template changes
sorted_rs=$(echo "$REPLICASETS_JSON" | jq 'sort_by(.metadata.creationTimestamp) | reverse')
latest=$(echo "$sorted_rs" | jq '.[0] // empty')
previous=$(echo "$sorted_rs" | jq '.[1] // empty')

if [[ -n "$previous" && "$previous" != "null" ]]; then
    latest_image=$(echo "$latest" | jq -r '.spec.template.spec.containers[0].image // ""')
    prev_image=$(echo "$previous" | jq -r '.spec.template.spec.containers[0].image // ""')
    latest_rev=$(echo "$latest" | jq -r '.metadata.annotations["deployment.kubernetes.io/revision"] // "?"')
    prev_rev=$(echo "$previous" | jq -r '.metadata.annotations["deployment.kubernetes.io/revision"] // "?"')

    changes=()
    [[ "$latest_image" != "$prev_image" ]] && changes+=("image: ${prev_image} -> ${latest_image}")

    latest_env_count=$(echo "$latest" | jq '.spec.template.spec.containers[0].env // [] | length')
    prev_env_count=$(echo "$previous" | jq '.spec.template.spec.containers[0].env // [] | length')
    [[ "$latest_env_count" != "$prev_env_count" ]] && changes+=("env var count: ${prev_env_count} -> ${latest_env_count}")

    latest_probe=$(echo "$latest" | jq -c '.spec.template.spec.containers[0].readinessProbe // {}')
    prev_probe=$(echo "$previous" | jq -c '.spec.template.spec.containers[0].readinessProbe // {}')
    [[ "$latest_probe" != "$prev_probe" ]] && changes+=("readinessProbe changed")

    latest_resources=$(echo "$latest" | jq -c '.spec.template.spec.containers[0].resources // {}')
    prev_resources=$(echo "$previous" | jq -c '.spec.template.spec.containers[0].resources // {}')
    [[ "$latest_resources" != "$prev_resources" ]] && changes+=("resources changed")

    updated_replicas=$(echo "$DEPLOYMENT_JSON" | jq '.status.updatedReplicas // 0')
    ready_replicas=$(echo "$DEPLOYMENT_JSON" | jq '.status.readyReplicas // 0')
    rollout_failing=false
    if [[ "$updated_replicas" -lt "$(echo "$DEPLOYMENT_JSON" | jq '.status.replicas // 0')" ]] || \
       [[ "$ready_replicas" -lt "$updated_replicas" ]]; then
        rollout_failing=true
    fi

    if [[ ${#changes[@]} -gt 0 && "$rollout_failing" == "true" ]]; then
        change_list=$(printf '%s; ' "${changes[@]}")
        add_issue "3" \
            "Recent Revision Changes May Correlate with Failed Rollout for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
            "Revision ${prev_rev} -> ${latest_rev} changes: ${change_list}. History:\n${history_output}" \
            "Rollback Deployment to revision ${prev_rev} in k8s-deployment-ops if the change caused the failure. Inspect New ReplicaSet Pod Failures."
    elif [[ ${#changes[@]} -gt 0 ]]; then
        change_list=$(printf '%s; ' "${changes[@]}")
        add_issue "4" \
            "Recent Template Changes for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
            "Latest revision ${latest_rev} differs from ${prev_rev}: ${change_list}" \
            "Use this context when correlating rollout issues with specific changes."
    fi
fi

write_issues "$OUTPUT_FILE"
echo "Analysis completed. Results saved to ${OUTPUT_FILE}"
