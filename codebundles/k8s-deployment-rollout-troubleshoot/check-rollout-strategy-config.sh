#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS: CONTEXT, NAMESPACE, DEPLOYMENT_NAME
# Outputs issues to check_rollout_strategy_config.json
# -----------------------------------------------------------------------------

: "${KUBERNETES_DISTRIBUTION_BINARY:=kubectl}"
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${DEPLOYMENT_NAME:?Must set DEPLOYMENT_NAME}"

OUTPUT_FILE="check_rollout_strategy_config.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=k8s-rollout-helpers.sh
source "${SCRIPT_DIR}/k8s-rollout-helpers.sh"

init_issues_json

echo "Checking rollout strategy configuration for deployment ${DEPLOYMENT_NAME}"

if ! fetch_deployment_json; then
    write_issues "$OUTPUT_FILE"
    exit 0
fi

strategy_type=$(echo "$DEPLOYMENT_JSON" | jq -r '.spec.strategy.type // "RollingUpdate"')
max_unavailable=$(echo "$DEPLOYMENT_JSON" | jq -r '.spec.strategy.rollingUpdate.maxUnavailable // "25%"')
max_surge=$(echo "$DEPLOYMENT_JSON" | jq -r '.spec.strategy.rollingUpdate.maxSurge // "25%"')
progress_deadline=$(echo "$DEPLOYMENT_JSON" | jq -r '.spec.progressDeadlineSeconds // 600')
revision_limit=$(echo "$DEPLOYMENT_JSON" | jq -r '.spec.revisionHistoryLimit // 10')
paused=$(echo "$DEPLOYMENT_JSON" | jq -r '.spec.paused // false')
replicas=$(echo "$DEPLOYMENT_JSON" | jq '.spec.replicas // 0')

echo "Strategy: ${strategy_type}, maxUnavailable=${max_unavailable}, maxSurge=${max_surge}, progressDeadlineSeconds=${progress_deadline}, revisionHistoryLimit=${revision_limit}, paused=${paused}"

if [[ "$paused" == "true" ]]; then
    add_issue "3" \
        "Deployment \`${DEPLOYMENT_NAME}\` Rollout is Paused in Namespace \`${NAMESPACE}\`" \
        "spec.paused=true prevents rollout progress." \
        "Resume rollout after verifying the desired template. Use k8s-deployment-ops Rollback Deployment if needed."
fi

if [[ "$strategy_type" == "Recreate" && "$replicas" -gt 1 ]]; then
    add_issue "4" \
        "Recreate Strategy May Cause Downtime for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
        "Deployment uses Recreate strategy with ${replicas} replicas. All pods terminate before new ones start." \
        "Expected for Recreate; confirm downtime window is acceptable. Consider RollingUpdate if zero-downtime is required."
fi

if [[ "$progress_deadline" -lt 120 && "$replicas" -gt 0 ]]; then
    add_issue "3" \
        "Short Progress Deadline for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
        "progressDeadlineSeconds=${progress_deadline} may mark slow-starting pods as failed too quickly." \
        "Increase progressDeadlineSeconds or optimize startup/readiness probes if rollouts fail prematurely."
fi

if [[ "$max_unavailable" == "0" || "$max_unavailable" == "0%" ]]; then
    if [[ "$max_surge" == "0" || "$max_surge" == "0%" ]]; then
        add_issue "3" \
            "Rollout Strategy Cannot Progress for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
            "Both maxUnavailable and maxSurge are 0. Rolling updates cannot replace pods." \
            "Adjust maxUnavailable or maxSurge to allow rollout progress."
    elif [[ "$replicas" -eq 1 ]]; then
        add_issue "4" \
            "Single-Replica Deployment with maxUnavailable=0 for \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
            "With 1 replica and maxUnavailable=0, rollout depends entirely on maxSurge=${max_surge}." \
            "Ensure maxSurge allows a temporary extra pod during rollout."
    fi
fi

if [[ "$max_unavailable" =~ ^[0-9]+$ ]] && [[ "$replicas" -gt 0 ]]; then
    if [[ "$max_unavailable" -eq 0 && ! "$max_surge" =~ ^[1-9] ]]; then
        add_issue "3" \
            "Restrictive Rollout Limits for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
            "maxUnavailable=0 with low maxSurge=${max_surge} can stall rollouts on small replica counts." \
            "Review maxSurge/maxUnavailable relative to replica count and PDB constraints."
    fi
fi

if [[ "$revision_limit" == "0" ]]; then
    add_issue "4" \
        "No Rollout History Retained for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
        "revisionHistoryLimit=0 prevents kubectl rollout undo." \
        "Set revisionHistoryLimit to at least 2 if rollback capability is needed."
fi

write_issues "$OUTPUT_FILE"
echo "Analysis completed. Results saved to ${OUTPUT_FILE}"
