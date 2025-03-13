#!/bin/bash

# Function to generate next steps based on the issue type
function generate_next_steps() {
    local ns="$1"
    local deployment="$2"
    local issue_type="$3"

    case "$issue_type" in
        "namespace_enabled_missing_sidecar")
            cat <<EOF
[
    "Check if the deployment was created before Istio installation",
    "Verify the deployment's pod template labels",
    "Try restarting the deployment: kubectl rollout restart deployment/$deployment -n $ns",
    "Check Istio injection webhook: kubectl get mutatingwebhookconfiguration -l app=sidecar-injector",
    "Verify namespace injection label: kubectl get namespace $ns -L istio-injection"
]
EOF
            ;;
        "deployment_enabled_missing_sidecar")
            cat <<EOF
[
    "Check if the deployment was created before Istio installation",
    "Verify the sidecar.istio.io/inject annotation is set to 'true'",
    "Try restarting the deployment: kubectl rollout restart deployment/$deployment -n $ns",
    "Check Istio injection webhook: kubectl get mutatingwebhookconfiguration -l app=sidecar-injector"
]
EOF
            ;;
        "not_configured_for_injection")
            cat <<EOF
[
    "If Istio sidecar injection is needed:",
    "  - Enable namespace-level injection: kubectl label namespace $ns istio-injection=enabled",
    "  - Or add deployment-level injection: kubectl patch deployment $deployment -n $ns -p '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"sidecar.istio.io/inject\":\"true\"}}}}}'",
    "Otherwise, no action needed - deployment is not meant to have Istio sidecar"
]
EOF
            ;;
    esac
}

# Read issues.json and format for RW.Core.Add Issue
if [ -f "issues.json" ]; then
    ISSUES=$(cat issues.json)
    if [ -n "$ISSUES" ]; then
        while read -r issue; do
            ns=$(echo "$issue" | jq -r '.namespace')
            deployment=$(echo "$issue" | jq -r '.deployment')
            type=$(echo "$issue" | jq -r '.type')
            details=$(echo "$issue" | jq -r '.details')
            next_steps=$(generate_next_steps "$ns" "$deployment" "$type")
            
            # Create formatted issue
            cat <<EOF
{
    "severity": "2",
    "title": "Missing Istio Sidecar",
    "namespace": "$ns",
    "deployment": "$deployment",
    "details": "$details",
    "next_steps": $next_steps
}
EOF
        done < <(echo "$ISSUES" | jq -c '.[]') | jq -s '.'
    else
        echo "[]"
    fi
else
    echo "[]"
fi 