#!/bin/bash

# Function to check if a command exists
function check_command_exists() {
    if ! command -v "$1" &> /dev/null; then
        echo "Error: $1 could not be found"
        exit 1
    fi
}

# Function to check cluster connectivity
function check_cluster_connection() {
    # Check available contexts
    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" config get-contexts "${CONTEXT}" --no-headers 2>&1 >/dev/null; then
        echo "=== Available Contexts ==="
        "${KUBERNETES_DISTRIBUTION_BINARY}" config get-contexts
        echo "Error: Unable to get cluster contexts"
        exit 1
    fi
    
    # Try cluster-info
    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" cluster-info --context="${CONTEXT}" 2>&1 >/dev/null; then
        echo "=== Cluster Info ==="
        "${KUBERNETES_DISTRIBUTION_BINARY}" cluster-info --context="${CONTEXT}"
        echo "Error: Unable to connect to the cluster. Please check your kubeconfig and cluster status."
        exit 1
    fi
    
    # Check API server availability
    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" get --raw="/api" --context="${CONTEXT}" 2>&1 >/dev/null; then
        echo "Error: Unable to reach Kubernetes API server"
        exit 1
    fi
}

# Function to handle JSON parsing errors
function check_jq_error() {
    if [ $? -ne 0 ]; then
        echo "Error: Failed to parse JSON output"
        exit 1
    fi
}

# Verify required commands exist
check_command_exists "${KUBERNETES_DISTRIBUTION_BINARY}"
check_command_exists jq

# Check cluster connectivity first
check_cluster_connection

# Get list of namespaces matching the pattern
NAMESPACES=$("${KUBERNETES_DISTRIBUTION_BINARY}" get namespaces --context="${CONTEXT}" -o json)
if [ $? -ne 0 ]; then
    echo "Error: Failed to get namespaces. Please check your permissions and cluster status."
    exit 1
fi

# Convert comma-separated EXCLUDED_NAMESPACES to jq array format
EXCLUDED_NS_ARRAY=$(echo "${EXCLUDED_NAMESPACES}" | jq -R 'split(",")')

# Filter namespaces excluding the specified ones
FILTERED_NAMESPACES=$(echo "$NAMESPACES" | jq -r --argjson excluded "${EXCLUDED_NS_ARRAY}" \
    '.items[].metadata.name | select(. as $ns | ($excluded | index($ns) | not))')
check_jq_error

if [ -z "$FILTERED_NAMESPACES" ]; then
    echo "Error: No namespaces found (excluding: ${EXCLUDED_NAMESPACES})"
    exit 1
fi

echo "Checking Istio sidecar injection status across namespaces..."
echo

# Initialize arrays for issues
declare -a all_issues=()
declare -a deployments_with_sidecar=()
declare -a deployments_missing_sidecar=()
declare -a deployments_not_configured=()
FOUND_ANY_DEPLOYMENTS=false

echo "===REPORT_START==="
# Check each namespace
for ns in $FILTERED_NAMESPACES; do
    echo "=== Analyzing namespace: $ns ==="
    
    # Check if namespace has istio-injection label
    NS_INJECTION_LABEL=$("${KUBERNETES_DISTRIBUTION_BINARY}" get namespace "$ns" --context="${CONTEXT}" -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo "Error: Failed to get namespace $ns details. Skipping..."
        continue
    fi
    echo "Namespace injection label: '$NS_INJECTION_LABEL'"
    
    # Get all deployments in the namespace
    DEPLOYMENTS=$("${KUBERNETES_DISTRIBUTION_BINARY}" get deployments -n "$ns" --context="${CONTEXT}" -o json 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo "Error: Failed to get deployments in namespace $ns. Skipping..."
        continue
    fi
    
    DEPLOYMENT_COUNT=$(echo "$DEPLOYMENTS" | jq -r '.items | length')
    check_jq_error
    echo "Found $DEPLOYMENT_COUNT deployments in namespace"
    
    if [ "$DEPLOYMENT_COUNT" -gt 0 ]; then
        FOUND_ANY_DEPLOYMENTS=true
    else
        echo "No deployments found in namespace $ns"
        continue
    fi
    
    # Process deployments without using a pipe to avoid subshell issues
    readarray -t DEPLOYMENT_NAMES < <(echo "$DEPLOYMENTS" | jq -r '.items[] | select(.spec.template.spec.containers != null) | .metadata.name')
    check_jq_error
    
    for deployment in "${DEPLOYMENT_NAMES[@]}"; do
        echo "--- Checking deployment: $deployment ---"
        
        if [ "$NS_INJECTION_LABEL" == "enabled" ]; then
            echo "Namespace has injection enabled"
            # Check if deployment explicitly disables injection
            INJECTION_ANNOTATION=$(echo "$DEPLOYMENTS" | jq -r --arg deployment "$deployment" '.items[] | select(.metadata.name == $deployment) | .spec.template.metadata.annotations."sidecar.istio.io/inject"')
            check_jq_error
            echo "Injection annotation: '$INJECTION_ANNOTATION'"
            
            if [ "$INJECTION_ANNOTATION" == "false" ]; then
                echo "Deployment '$deployment' in namespace '$ns' has explicitly disabled Istio injection"
                continue
            fi
            
            # Get pods for this deployment
            PODS=$("${KUBERNETES_DISTRIBUTION_BINARY}" get pods -n "$ns" -l "app=${deployment}" --context="${CONTEXT}" -o json 2>/dev/null)
            PODS_COUNT=$(echo "$PODS" | jq -r '.items | length')
            
            # If no pods found with app label, try with istio canonical-name
            if [ "$PODS_COUNT" -eq 0 ]; then
                PODS=$("${KUBERNETES_DISTRIBUTION_BINARY}" get pods -n "$ns" -l "service.istio.io/canonical-name=${deployment}" --context="${CONTEXT}" -o json 2>/dev/null)
                if [ $? -ne 0 ]; then
                    echo "Error: Failed to get pods for deployment $deployment. Skipping..."
                    continue
                fi
                echo "Using istio canonical-name label to find pods"
            else
                echo "Using app label to find pods"
            fi
            
            # Check if any running pods have the istio-proxy container
            RUNNING_PODS_WITH_SIDECAR=$(echo "$PODS" | jq -r '.items[] | select(.status.phase == "Running") | select(.spec.containers[] | select(.name == "istio-proxy")) | .metadata.name')
            RUNNING_PODS_COUNT=$(echo "$PODS" | jq -r '.items[] | select(.status.phase == "Running") | .metadata.name' | wc -l)
            
            echo "Running pods: $RUNNING_PODS_COUNT"
            echo "Pods with sidecar: $(echo "$RUNNING_PODS_WITH_SIDECAR" | wc -l)"
            
            if [ "$RUNNING_PODS_COUNT" -eq 0 ]; then
                echo "WARNING: No running pods found for deployment $deployment with either app label or canonical-name"
                continue
            fi
            
            if [ -z "$RUNNING_PODS_WITH_SIDECAR" ]; then
                echo "WARNING: No pods have sidecar but namespace has injection enabled"
                issue=$(jq -n \
                    --arg ns "$ns" \
                    --arg deployment "$deployment" \
                    --arg details "Deployment $deployment in namespace $ns should have Istio sidecar (namespace injection enabled) but pods are missing it" \
                    --arg reproduce "kubectl get pods -n $ns -l app=$deployment -o jsonpath='{.items[*].spec.containers[*].name}'" \
                    --arg restart_cmd "kubectl rollout restart deployment/$deployment -n $ns" \
                    '{
                        namespace: $ns,
                        deployment: $deployment,
                        type: "namespace_enabled_missing_sidecar",
                        severity: 2,
                        title: "Missing Istio Sidecar - Namespace Injection",
                        details: $details,
                        reproduce_hint: $reproduce,
                        next_steps: [
                            "Check if pods were created before Istio installation",
                            "Verify the Istio injection webhook is working",
                            "Try restarting the deployment: \( $restart_cmd | @json )"
                        ]
                    }')
                all_issues+=("$issue")
                deployments_missing_sidecar+=("$deployment")
            else
                echo "Deployment '$deployment' in namespace '$ns' has pods with Istio sidecar properly configured"
                deployments_with_sidecar+=("$deployment")
            fi
        else
            echo "Namespace does not have injection enabled"
            # Check deployment spec for sidecar container
            HAS_SIDECAR=$(echo "$DEPLOYMENTS" | jq --arg deployment "$deployment" '.items[] | select(.metadata.name == $deployment) | .spec.template.spec.containers[] | select(.name == "istio-proxy") | .name')
            check_jq_error
            echo "Sidecar check result: '$HAS_SIDECAR'"
            
            # Only check for sidecar if deployment explicitly enables injection
            INJECTION_ANNOTATION=$(echo "$DEPLOYMENTS" | jq -r --arg deployment "$deployment" '.items[] | select(.metadata.name == $deployment) | .spec.template.metadata.annotations."sidecar.istio.io/inject"')
            check_jq_error
            echo "Injection annotation: '$INJECTION_ANNOTATION'"
            
            if echo "$DEPLOYMENTS" | jq -e --arg deployment "$deployment" '.items[] | select(.metadata.name == $deployment) | .spec.template.metadata.annotations | has("sidecar.istio.io/inject")' >/dev/null; then
                if [ "$INJECTION_ANNOTATION" == "true" ] && [ -z "$HAS_SIDECAR" ]; then
                    echo "Deployment '$deployment' in namespace '$ns' is missing Istio sidecar (deployment injection enabled)."
                    deployments_missing_sidecar+=("$deployment")
                    issue=$(jq -n \
                        --arg ns "$ns" \
                        --arg deployment "$deployment" \
                        --arg details "Deployment $deployment in namespace $ns should have Istio sidecar (explicitly enabled) but it's missing" \
                        --arg reproduce "kubectl get pods -n $ns -l app=$deployment -o jsonpath='{.items[*].spec.containers[*].name}'" \
                        --arg restart_cmd "kubectl rollout restart deployment/$deployment -n $ns" \
                        '{
                            namespace: $ns,
                            deployment: $deployment,
                            type: "deployment_enabled_missing_sidecar",
                            severity: 2,
                            title: "Missing Istio Sidecar - Deployment Injection",
                            details: $details,
                            reproduce_hint: $reproduce,
                            next_steps: [
                                "Check if the deployment was created before Istio installation",
                                "Verify the sidecar.istio.io/inject annotation is set correctly",
                                "Try restarting the deployment: \( $restart_cmd | @json )"
                            ]
                        }')
                    all_issues+=("$issue")
                else
                    echo "Deployment '$deployment' in namespace '$ns' has Istio sidecar properly configured"
                    deployments_with_sidecar+=("$deployment")
                fi
            else
                echo "Deployment '$deployment' in namespace '$ns' is NOT properly configured (no injection label, no annotation)."
                deployments_not_configured+=("$deployment")
                issue=$(jq -n \
                    --arg ns "$ns" \
                    --arg deployment "$deployment" \
                    --arg details "Deployment $deployment in namespace $ns is missing both namespace injection and annotation." \
                    --arg reproduce "kubectl get namespace $ns -L istio-injection && kubectl get deployment $deployment -n $ns -o jsonpath='{.spec.template.metadata.annotations}'" \
                    --arg patch_cmd "kubectl patch deployment $deployment -n $ns -p '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"sidecar.istio.io/inject\":\"true\"}}}}}'" \
                    '{
                        "namespace": $ns,
                        "deployment": $deployment,
                        "type": "not_properly_configured",
                        "severity": 3,
                        "title": "Istio Injection Not Configured",
                        "details": $details,
                        "reproduce_hint": $reproduce,
                        "next_steps": [
                            "Enable namespace-level injection: kubectl label namespace \($ns) istio-injection=enabled",
                            ("Or add deployment-level injection: " + $patch_cmd)
                        ]
                    }')

                all_issues+=("$issue")
            fi
        fi
        echo
    done
    echo
done

# Add deployment summary
echo "=== Deployment Summary ==="
if [ ${#deployments_with_sidecar[@]} -gt 0 ]; then
    echo "Deployments with sidecar: ${deployments_with_sidecar[*]}"
fi
if [ ${#deployments_missing_sidecar[@]} -gt 0 ]; then
    echo "Deployments missing sidecar: ${deployments_missing_sidecar[*]}"
fi
if [ ${#deployments_not_configured[@]} -gt 0 ]; then
    echo "Deployments not configured for injection: ${deployments_not_configured[*]}"
fi
echo "===REPORT_END==="

if [ "$FOUND_ANY_DEPLOYMENTS" = false ]; then
    echo "Error: No deployments found in any of the matching namespaces"
    exit 1
fi

# Write issues to stdout with markers
if [ ${#all_issues[@]} -gt 0 ]; then
    echo "===ISSUES_START==="
    printf "%s\n" "${all_issues[@]}" | jq -s .
    echo "===ISSUES_END==="
else
    echo "===ISSUES_START==="
    echo "[]"
    echo "===ISSUES_END==="
fi