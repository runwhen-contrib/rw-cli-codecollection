#!/usr/bin/env bash
# Shared helpers for k8s-deployment-rollout-troubleshoot scripts.
# Source this file; do not execute directly.

: "${KUBERNETES_DISTRIBUTION_BINARY:=kubectl}"
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${DEPLOYMENT_NAME:?Must set DEPLOYMENT_NAME}"

K8S_CMD=( "${KUBERNETES_DISTRIBUTION_BINARY}" --context "${CONTEXT}" -n "${NAMESPACE}" )

init_issues_json() {
    issues_json='[]'
}

add_issue() {
    local severity="$1"
    local title="$2"
    local details="$3"
    local next_steps="$4"
    issues_json=$(echo "$issues_json" | jq \
        --arg title "$title" \
        --arg details "$details" \
        --arg severity "$severity" \
        --arg next_steps "$next_steps" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
}

write_issues() {
    local output_file="$1"
    echo "$issues_json" > "$output_file"
}

fetch_deployment_json() {
    if ! DEPLOYMENT_JSON=$("${K8S_CMD[@]}" get deployment "${DEPLOYMENT_NAME}" -o json 2>deployment_err.log); then
        local err_msg
        err_msg=$(cat deployment_err.log)
        rm -f deployment_err.log
        add_issue "4" \
            "Cannot Access Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
            "Failed to fetch deployment: ${err_msg}" \
            "Verify kubeconfig RBAC permissions and that deployment ${DEPLOYMENT_NAME} exists in namespace ${NAMESPACE}."
        return 1
    fi
    rm -f deployment_err.log
    return 0
}

fetch_deployment_replicasets_json() {
    REPLICASETS_JSON=$("${K8S_CMD[@]}" get rs -o json | jq --arg DEPLOYMENT_NAME "$DEPLOYMENT_NAME" \
        '[.items[] | select(.metadata.ownerReferences[]? | select(.kind == "Deployment" and .name == $DEPLOYMENT_NAME))]')
}

get_latest_replicaset_name() {
    echo "$REPLICASETS_JSON" | jq -r 'sort_by(.metadata.creationTimestamp) | last(.[]?) | .metadata.name // empty'
}

get_deployment_selector() {
    echo "$DEPLOYMENT_JSON" | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")'
}

get_deployment_pods_json() {
    local selector
    selector=$(get_deployment_selector)
    if [[ -z "$selector" ]]; then
        PODS_JSON='{"items":[]}'
        return
    fi
    PODS_JSON=$("${K8S_CMD[@]}" get pods -l "$selector" -o json 2>/dev/null || echo '{"items":[]}')
}

get_latest_replicaset_pods_json() {
    local latest_rs="$1"
    PODS_JSON=$("${K8S_CMD[@]}" get pods -o json | jq --arg rs "$latest_rs" \
        '[.items[] | select(.metadata.ownerReferences[]? | select(.kind == "ReplicaSet" and .name == $rs))] | {items: .}')
}

parse_duration_to_seconds() {
    local value="$1"
    if [[ "$value" =~ ^([0-9]+)m$ ]]; then
        echo $(( ${BASH_REMATCH[1]} * 60 ))
    elif [[ "$value" =~ ^([0-9]+)h$ ]]; then
        echo $(( ${BASH_REMATCH[1]} * 3600 ))
    elif [[ "$value" =~ ^([0-9]+)s$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "$value"
    else
        echo "1800"
    fi
}
