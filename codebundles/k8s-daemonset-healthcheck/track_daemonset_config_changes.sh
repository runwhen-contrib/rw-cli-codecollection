#!/bin/bash

# Track DaemonSet configuration changes by analyzing ControllerRevisions
# This script provides configuration change analysis for DaemonSets

set -eo pipefail

# Required parameters
DAEMONSET_NAME="${1:-}"
NAMESPACE="${2:-}"
CONTEXT="${3:-}"
TIME_WINDOW="${4:-24h}"

if [[ -z "$DAEMONSET_NAME" || -z "$NAMESPACE" || -z "$CONTEXT" ]]; then
    echo "Usage: $0 <daemonset_name> <namespace> <context> [time_window]"
    exit 1
fi

# Convert time window to seconds for comparison
case "$TIME_WINDOW" in
    *h) HOURS=${TIME_WINDOW%h}; SECONDS_AGO=$((HOURS * 3600)) ;;
    *m) MINUTES=${TIME_WINDOW%m}; SECONDS_AGO=$((MINUTES * 60)) ;;
    *d) DAYS=${TIME_WINDOW%d}; SECONDS_AGO=$((DAYS * 86400)) ;;
    *) SECONDS_AGO=86400 ;; # Default to 24 hours
esac

CUTOFF_TIME=$(date -d "@$(($(date +%s) - SECONDS_AGO))" -u +"%Y-%m-%dT%H:%M:%SZ")

echo "=== DaemonSet Configuration Change Analysis ==="
echo "DaemonSet: $DAEMONSET_NAME"
echo "Namespace: $NAMESPACE" 
echo "Context: $CONTEXT"
echo "Time Window: $TIME_WINDOW (since $CUTOFF_TIME)"
echo

# Check if context exists
if ! ${KUBERNETES_DISTRIBUTION_BINARY} config get-contexts "$CONTEXT" >/dev/null 2>&1; then
    echo "ERROR: Context '$CONTEXT' not found"
    exit 0  # Exit gracefully like other tasks
fi

# Check if DaemonSet exists
if ! ${KUBERNETES_DISTRIBUTION_BINARY} get daemonset "$DAEMONSET_NAME" --context "$CONTEXT" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "ERROR: DaemonSet '$DAEMONSET_NAME' not found in namespace '$NAMESPACE' with context '$CONTEXT'"
    exit 0  # Exit gracefully like other tasks
fi

# Get ControllerRevisions owned by this DaemonSet, sorted by creation time (newest first)
echo "=== ControllerRevision Analysis ==="
REVISIONS=$(${KUBERNETES_DISTRIBUTION_BINARY} get controllerrevisions --context "$CONTEXT" -n "$NAMESPACE" -o json | \
    jq -r --arg daemonset "$DAEMONSET_NAME" '
    [.items[] | select(
        .metadata.ownerReferences[]? | 
        select(.kind == "DaemonSet" and .name == $daemonset)
    )] | 
    sort_by(.metadata.creationTimestamp) | 
    reverse | 
    .[] | 
    "\(.metadata.name)|\(.metadata.creationTimestamp)|\(.revision // 0)"
')

if [[ -z "$REVISIONS" ]]; then
    echo "No ControllerRevisions found for DaemonSet $DAEMONSET_NAME"
    exit 0
fi

# Parse ControllerRevisions
declare -a REV_NAMES=()
declare -a REV_TIMES=()
declare -a REV_NUMBERS=()

while IFS='|' read -r name timestamp revision; do
    REV_NAMES+=("$name")
    REV_TIMES+=("$timestamp")
    REV_NUMBERS+=("$revision")
done <<< "$REVISIONS"

CURRENT_REV="${REV_NAMES[0]}"
CURRENT_TIME="${REV_TIMES[0]}"
CURRENT_REV_NUM="${REV_NUMBERS[0]}"

echo "Current ControllerRevision: $CURRENT_REV (created: $CURRENT_TIME, revision: $CURRENT_REV_NUM)"

# Check if current ControllerRevision was created within time window
if [[ "$CURRENT_TIME" > "$CUTOFF_TIME" ]]; then
    echo "✅ Recent ControllerRevision change detected within $TIME_WINDOW"
    
    if [[ ${#REV_NAMES[@]} -gt 1 ]]; then
        PREVIOUS_REV="${REV_NAMES[1]}"
        PREVIOUS_TIME="${REV_TIMES[1]}"
        PREVIOUS_REV_NUM="${REV_NUMBERS[1]}"
        echo "Previous ControllerRevision: $PREVIOUS_REV (created: $PREVIOUS_TIME, revision: $PREVIOUS_REV_NUM)"
        
        # Get detailed comparison between current and previous ControllerRevision
        echo
        echo "=== Configuration Comparison ==="
        
        # Get current ControllerRevision data
        CURRENT_DATA=$(${KUBERNETES_DISTRIBUTION_BINARY} get controllerrevision "$CURRENT_REV" --context "$CONTEXT" -n "$NAMESPACE" -o json | \
            jq '.data')
        
        # Get previous ControllerRevision data
        PREVIOUS_DATA=$(${KUBERNETES_DISTRIBUTION_BINARY} get controllerrevision "$PREVIOUS_REV" --context "$CONTEXT" -n "$NAMESPACE" -o json | \
            jq '.data')
        
        # Compare pod template (DaemonSet spec)
        CURRENT_TEMPLATE=$(echo "$CURRENT_DATA" | jq '.spec.template // empty')
        PREVIOUS_TEMPLATE=$(echo "$PREVIOUS_DATA" | jq '.spec.template // empty')
        
        if [[ -n "$CURRENT_TEMPLATE" && -n "$PREVIOUS_TEMPLATE" && "$CURRENT_TEMPLATE" != "$PREVIOUS_TEMPLATE" ]]; then
            # Compare container images
            CURRENT_IMAGES=$(echo "$CURRENT_TEMPLATE" | jq -r '.spec.containers[]? | "\(.name):\(.image)"' | sort)
            PREVIOUS_IMAGES=$(echo "$PREVIOUS_TEMPLATE" | jq -r '.spec.containers[]? | "\(.name):\(.image)"' | sort)
            
            if [[ "$CURRENT_IMAGES" != "$PREVIOUS_IMAGES" ]]; then
                echo "🔄 Container Image Changes Detected:"
                echo "Previous images:"
                echo "$PREVIOUS_IMAGES" | sed 's/^/  - /'
                echo "Current images:"
                echo "$CURRENT_IMAGES" | sed 's/^/  - /'
                echo
            fi
            
            # Compare environment variables (detailed)
            CURRENT_ENV=$(echo "$CURRENT_TEMPLATE" | jq -r '.spec.containers[]?.env[]? | "\(.name)=\(.value // .valueFrom.secretKeyRef.name // .valueFrom.configMapKeyRef.name // "ref")"' | sort)
            PREVIOUS_ENV=$(echo "$PREVIOUS_TEMPLATE" | jq -r '.spec.containers[]?.env[]? | "\(.name)=\(.value // .valueFrom.secretKeyRef.name // .valueFrom.configMapKeyRef.name // "ref")"' | sort)
            
            if [[ "$CURRENT_ENV" != "$PREVIOUS_ENV" ]]; then
                echo "🔧 Environment Variable Changes Detected:"
                
                # Show added variables
                ADDED_VARS=$(comm -13 <(echo "$PREVIOUS_ENV") <(echo "$CURRENT_ENV") | head -10)
                if [[ -n "$ADDED_VARS" ]]; then
                    echo "  ➕ Added variables:"
                    echo "$ADDED_VARS" | sed 's/^/    /'
                fi
                
                # Show removed variables  
                REMOVED_VARS=$(comm -23 <(echo "$PREVIOUS_ENV") <(echo "$CURRENT_ENV") | head -10)
                if [[ -n "$REMOVED_VARS" ]]; then
                    echo "  ➖ Removed variables:"
                    echo "$REMOVED_VARS" | sed 's/^/    /'
                fi
                
                # Show modified variables (same name, different value)
                CURRENT_NAMES=$(echo "$CURRENT_ENV" | cut -d'=' -f1 | sort)
                PREVIOUS_NAMES=$(echo "$PREVIOUS_ENV" | cut -d'=' -f1 | sort)
                COMMON_NAMES=$(comm -12 <(echo "$CURRENT_NAMES") <(echo "$PREVIOUS_NAMES"))
                
                if [[ -n "$COMMON_NAMES" ]]; then
                    MODIFIED_VARS=""
                    while read -r var_name; do
                        CURRENT_VAL=$(echo "$CURRENT_ENV" | grep "^$var_name=" | head -1)
                        PREVIOUS_VAL=$(echo "$PREVIOUS_ENV" | grep "^$var_name=" | head -1)
                        if [[ "$CURRENT_VAL" != "$PREVIOUS_VAL" && -n "$CURRENT_VAL" && -n "$PREVIOUS_VAL" ]]; then
                            MODIFIED_VARS+="    $var_name: $(echo "$PREVIOUS_VAL" | cut -d'=' -f2-) → $(echo "$CURRENT_VAL" | cut -d'=' -f2-)\n"
                        fi
                    done <<< "$COMMON_NAMES"
                    
                    if [[ -n "$MODIFIED_VARS" ]]; then
                        echo "  🔄 Modified variables:"
                        echo -e "$MODIFIED_VARS"
                    fi
                fi
                
                echo "  📊 Summary: $(echo "$PREVIOUS_ENV" | wc -l) → $(echo "$CURRENT_ENV" | wc -l) variables"
                echo
            fi
            
            # Compare resource requirements (detailed for DaemonSets)
            CURRENT_RESOURCES=$(echo "$CURRENT_TEMPLATE" | jq -c '.spec.containers[]? | {name: .name, resources: .resources}')
            PREVIOUS_RESOURCES=$(echo "$PREVIOUS_TEMPLATE" | jq -c '.spec.containers[]? | {name: .name, resources: .resources}')
            
            if [[ "$CURRENT_RESOURCES" != "$PREVIOUS_RESOURCES" ]]; then
                echo "📊 Resource Requirement Changes Detected:"
                
                # Show detailed resource comparison
                echo "Previous resources:"
                echo "$PREVIOUS_TEMPLATE" | jq -r '.spec.containers[]? | "  - \(.name): CPU=\(.resources.requests.cpu // "none")/\(.resources.limits.cpu // "none") MEM=\(.resources.requests.memory // "none")/\(.resources.limits.memory // "none")"'
                echo "Current resources:"
                echo "$CURRENT_TEMPLATE" | jq -r '.spec.containers[]? | "  - \(.name): CPU=\(.resources.requests.cpu // "none")/\(.resources.limits.cpu // "none") MEM=\(.resources.requests.memory // "none")/\(.resources.limits.memory // "none")"'
                echo
            fi
            
            # Compare node scheduling (DaemonSet-specific: nodeSelector, tolerations, affinity)
            CURRENT_NODE_SELECTOR=$(echo "$CURRENT_TEMPLATE" | jq -c '.spec.nodeSelector // {}')
            PREVIOUS_NODE_SELECTOR=$(echo "$PREVIOUS_TEMPLATE" | jq -c '.spec.nodeSelector // {}')
            
            if [[ "$CURRENT_NODE_SELECTOR" != "$PREVIOUS_NODE_SELECTOR" ]]; then
                echo "🎯 Node Selector Changes Detected:"
                echo "Previous nodeSelector:"
                echo "$PREVIOUS_NODE_SELECTOR" | jq -r 'to_entries[] | "  - \(.key)=\(.value)"'
                echo "Current nodeSelector:"
                echo "$CURRENT_NODE_SELECTOR" | jq -r 'to_entries[] | "  - \(.key)=\(.value)"'
                echo
            fi
            
            # Compare tolerations (critical for DaemonSets)
            CURRENT_TOLERATIONS=$(echo "$CURRENT_TEMPLATE" | jq -c '.spec.tolerations // []')
            PREVIOUS_TOLERATIONS=$(echo "$PREVIOUS_TEMPLATE" | jq -c '.spec.tolerations // []')
            
            if [[ "$CURRENT_TOLERATIONS" != "$PREVIOUS_TOLERATIONS" ]]; then
                echo "🛡️ Toleration Changes Detected:"
                echo "Previous tolerations:"
                echo "$PREVIOUS_TOLERATIONS" | jq -r '.[] | "  - key=\(.key // "none") operator=\(.operator // "Equal") value=\(.value // "none") effect=\(.effect // "none")"'
                echo "Current tolerations:"
                echo "$CURRENT_TOLERATIONS" | jq -r '.[] | "  - key=\(.key // "none") operator=\(.operator // "Equal") value=\(.value // "none") effect=\(.effect // "none")"'
                echo
            fi
            
            # Compare host networking and security context (DaemonSet-specific)
            CURRENT_HOST_NETWORK=$(echo "$CURRENT_TEMPLATE" | jq -r '.spec.hostNetwork // false')
            PREVIOUS_HOST_NETWORK=$(echo "$PREVIOUS_TEMPLATE" | jq -r '.spec.hostNetwork // false')
            
            if [[ "$CURRENT_HOST_NETWORK" != "$PREVIOUS_HOST_NETWORK" ]]; then
                echo "🌐 Host Network Changes Detected:"
                echo "Previous hostNetwork: $PREVIOUS_HOST_NETWORK"
                echo "Current hostNetwork: $CURRENT_HOST_NETWORK"
                echo
            fi
            
            # Compare security context
            CURRENT_SECURITY_CONTEXT=$(echo "$CURRENT_TEMPLATE" | jq -c '.spec.securityContext // {}')
            PREVIOUS_SECURITY_CONTEXT=$(echo "$PREVIOUS_TEMPLATE" | jq -c '.spec.securityContext // {}')
            
            if [[ "$CURRENT_SECURITY_CONTEXT" != "$PREVIOUS_SECURITY_CONTEXT" ]]; then
                echo "🔒 Security Context Changes Detected:"
                echo "Previous securityContext: $PREVIOUS_SECURITY_CONTEXT"
                echo "Current securityContext: $CURRENT_SECURITY_CONTEXT"
                echo
            fi
        fi
    else
        echo "No previous ControllerRevision found for comparison"
    fi
else
    echo "ℹ️  No recent ControllerRevision changes within $TIME_WINDOW"
fi

echo
echo "=== kubectl apply Status ==="

# Check for recent kubectl apply operations
DAEMONSET_JSON=$(${KUBERNETES_DISTRIBUTION_BINARY} get daemonset "$DAEMONSET_NAME" --context "$CONTEXT" -n "$NAMESPACE" -o json)

# Check for last-applied-configuration annotation
LAST_APPLIED=$(echo "$DAEMONSET_JSON" | jq -r '.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"] // "null"')

if [[ "$LAST_APPLIED" != "null" ]]; then
    echo "✅ kubectl apply annotation found"
    
    # Check generation vs observedGeneration
    GENERATION=$(echo "$DAEMONSET_JSON" | jq -r '.metadata.generation // 0')
    OBSERVED_GENERATION=$(echo "$DAEMONSET_JSON" | jq -r '.status.observedGeneration // 0')
    
    if [[ "$GENERATION" -gt "$OBSERVED_GENERATION" ]]; then
        GAP=$((GENERATION - OBSERVED_GENERATION))
        echo "⚠️  Recent kubectl apply detected: Generation $GENERATION vs Observed $OBSERVED_GENERATION (gap: $GAP)"
    else
        echo "ℹ️  No recent kubectl apply detected"
    fi
else
    echo "ℹ️  No kubectl apply annotation found"
fi

echo
echo "=== Configuration Drift Check ==="

GENERATION=$(echo "$DAEMONSET_JSON" | jq -r '.metadata.generation // 0')
OBSERVED_GENERATION=$(echo "$DAEMONSET_JSON" | jq -r '.status.observedGeneration // 0')

if [[ "$GENERATION" -gt "$OBSERVED_GENERATION" ]]; then
    DRIFT_AMOUNT=$((GENERATION - OBSERVED_GENERATION))
    echo "⚠️  Configuration drift detected: $DRIFT_AMOUNT generation(s) ahead"
    echo
    echo "📋 Drift Analysis:"
    echo "  • metadata.generation: $GENERATION (desired configuration version)"
    echo "  • status.observedGeneration: $OBSERVED_GENERATION (controller's processed version)"
    echo "  • Gap: $DRIFT_AMOUNT generation(s)"
    echo
    echo "🔍 Possible causes:"
    echo "  • Recent kubectl apply/patch operations"
    echo "  • Controller processing delays"
    echo "  • Resource constraints preventing updates"
    echo "  • Node scheduling issues (for DaemonSets)"
    echo
    echo "📊 Current DaemonSet conditions:"
    echo "$DAEMONSET_JSON" | jq -r '.status.conditions[]? | "  • \(.type): \(.status) - \(.reason // "N/A") (\(.lastTransitionTime))"'
    echo
else
    echo "✅ No configuration drift detected"
    echo "  • metadata.generation: $GENERATION"
    echo "  • status.observedGeneration: $OBSERVED_GENERATION"
    echo "  • Status: Synchronized"
fi

echo
echo "=== Summary ==="
echo "Analysis completed for DaemonSet $DAEMONSET_NAME in namespace $NAMESPACE"
echo "Current ControllerRevision: $CURRENT_REV (revision: $CURRENT_REV_NUM)"
echo "ControllerRevision created: $CURRENT_TIME"

# Format timestamp for display
FORMATTED_TIME=$(date -d "$CURRENT_TIME" "+%Y-%m-%d %H:%M:%S UTC" 2>/dev/null || echo "$CURRENT_TIME")
echo "Last change time: $FORMATTED_TIME"
echo
echo "⚠️  Note: DaemonSets use ControllerRevisions to track configuration changes and update pods across all nodes."
echo "🎯 DaemonSet-specific considerations: node scheduling, tolerations, host networking, and security contexts."
