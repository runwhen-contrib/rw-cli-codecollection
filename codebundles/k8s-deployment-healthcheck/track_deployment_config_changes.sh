#!/bin/bash

# Track deployment configuration changes by analyzing ReplicaSets
# This script provides the same functionality as the Robot Keywords but uses bash/kubectl directly

set -eo pipefail

# Required parameters
DEPLOYMENT_NAME="${1:-}"
NAMESPACE="${2:-}"
CONTEXT="${3:-}"
TIME_WINDOW="${4:-24h}"

if [[ -z "$DEPLOYMENT_NAME" || -z "$NAMESPACE" || -z "$CONTEXT" ]]; then
    echo "Usage: $0 <deployment_name> <namespace> <context> [time_window]"
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

echo "=== Deployment Configuration Change Analysis ==="
echo "Deployment: $DEPLOYMENT_NAME"
echo "Namespace: $NAMESPACE" 
echo "Context: $CONTEXT"
echo "Time Window: $TIME_WINDOW (since $CUTOFF_TIME)"
echo

# Check if deployment exists
if ! ${KUBERNETES_DISTRIBUTION_BINARY} get deployment "$DEPLOYMENT_NAME" --context "$CONTEXT" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "ERROR: Deployment '$DEPLOYMENT_NAME' not found in namespace '$NAMESPACE' with context '$CONTEXT'"
    exit 0  # Exit gracefully like other tasks
fi

# Get ReplicaSets owned by this deployment, sorted by creation time (newest first)
echo "=== ReplicaSet Analysis ==="
REPLICASETS=$(${KUBERNETES_DISTRIBUTION_BINARY} get rs --context "$CONTEXT" -n "$NAMESPACE" -o json | \
    jq -r --arg deployment "$DEPLOYMENT_NAME" '
    [.items[] | select(
        .metadata.ownerReferences[]? | 
        select(.kind == "Deployment" and .name == $deployment)
    )] | 
    sort_by(.metadata.creationTimestamp) | 
    reverse | 
    .[] | 
    "\(.metadata.name)|\(.metadata.creationTimestamp)|\(.spec.replicas // 0)"
')

if [[ -z "$REPLICASETS" ]]; then
    echo "No ReplicaSets found for deployment $DEPLOYMENT_NAME"
    exit 0
fi

# Parse ReplicaSets
declare -a RS_NAMES=()
declare -a RS_TIMES=()
declare -a RS_REPLICAS=()

while IFS='|' read -r name timestamp replicas; do
    RS_NAMES+=("$name")
    RS_TIMES+=("$timestamp")
    RS_REPLICAS+=("$replicas")
done <<< "$REPLICASETS"

CURRENT_RS="${RS_NAMES[0]}"
CURRENT_TIME="${RS_TIMES[0]}"

echo "Current ReplicaSet: $CURRENT_RS (created: $CURRENT_TIME)"

# Check if current ReplicaSet was created within time window
if [[ "$CURRENT_TIME" > "$CUTOFF_TIME" ]]; then
    echo "✅ Recent ReplicaSet change detected within $TIME_WINDOW"
    
    if [[ ${#RS_NAMES[@]} -gt 1 ]]; then
        PREVIOUS_RS="${RS_NAMES[1]}"
        PREVIOUS_TIME="${RS_TIMES[1]}"
        echo "Previous ReplicaSet: $PREVIOUS_RS (created: $PREVIOUS_TIME)"
        
        # Get detailed comparison between current and previous ReplicaSet
        echo
        echo "=== Configuration Comparison ==="
        
        # Get current ReplicaSet pod template
        CURRENT_TEMPLATE=$(${KUBERNETES_DISTRIBUTION_BINARY} get rs "$CURRENT_RS" --context "$CONTEXT" -n "$NAMESPACE" -o json | \
            jq '.spec.template')
        
        # Get previous ReplicaSet pod template  
        PREVIOUS_TEMPLATE=$(${KUBERNETES_DISTRIBUTION_BINARY} get rs "$PREVIOUS_RS" --context "$CONTEXT" -n "$NAMESPACE" -o json | \
            jq '.spec.template')
        
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
        
        # Compare resource requirements (detailed)
        CURRENT_RESOURCES=$(echo "$CURRENT_TEMPLATE" | jq -r '.spec.containers[]? | "\(.name): CPU=\(.resources.requests.cpu // "none")/\(.resources.limits.cpu // "none") MEM=\(.resources.requests.memory // "none")/\(.resources.limits.memory // "none")"')
        PREVIOUS_RESOURCES=$(echo "$PREVIOUS_TEMPLATE" | jq -r '.spec.containers[]? | "\(.name): CPU=\(.resources.requests.cpu // "none")/\(.resources.limits.cpu // "none") MEM=\(.resources.requests.memory // "none")/\(.resources.limits.memory // "none")"')
        
        if [[ "$CURRENT_RESOURCES" != "$PREVIOUS_RESOURCES" ]]; then
            echo "📊 Resource Requirement Changes Detected:"
            echo "Previous resources:"
            echo "$PREVIOUS_RESOURCES" | sed 's/^/  - /'
            echo "Current resources:"
            echo "$CURRENT_RESOURCES" | sed 's/^/  - /'
            echo
        fi
    else
        echo "No previous ReplicaSet found for comparison"
    fi
else
    echo "ℹ️  No recent ReplicaSet changes within $TIME_WINDOW"
fi

echo
echo "=== Rollback Detection ==="

# Method 1: Check for rollback-related Kubernetes events
ROLLBACK_EVENT_DETAILS=""
if EVENTS_JSON=$(${KUBERNETES_DISTRIBUTION_BINARY} get events --context "$CONTEXT" -n "$NAMESPACE" -o json 2>/dev/null); then
    ROLLBACK_EVENT_DETAILS=$(echo "$EVENTS_JSON" | jq -r --arg name "$DEPLOYMENT_NAME" --arg cutoff "$CUTOFF_TIME" '
        [.items[] | select(
            .involvedObject.name == $name and
            .involvedObject.kind == "Deployment" and
            .reason == "DeploymentRollback" and
            (.lastTimestamp // .metadata.creationTimestamp) > $cutoff
        )] | if length > 0 then .[] | "  \(.lastTimestamp // .metadata.creationTimestamp): [\(.reason)] \(.message)" else empty end')
fi

# Method 2: Check ReplicaSet pattern - an older RS being active while a newer RS has been scaled down
# After a rollback, the most recently created RS (the failed deployment) gets scaled to 0,
# while an older RS (the rollback target) becomes active again
ROLLBACK_PATTERN_DETECTED=false
ROLLBACK_NEWEST_RS=""
ROLLBACK_ACTIVE_RS=""
ROLLBACK_ACTIVE_TIME=""

if [[ ${#RS_NAMES[@]} -gt 1 ]]; then
    # RS_NAMES[0] is the newest by creation time (sorted newest first)
    NEWEST_RS_NAME="${RS_NAMES[0]}"
    NEWEST_RS_REPLICAS="${RS_REPLICAS[0]}"
    NEWEST_RS_TIME="${RS_TIMES[0]}"

    # Find the active RS (first with replicas > 0)
    for ((i=0; i<${#RS_NAMES[@]}; i++)); do
        if [[ "${RS_REPLICAS[$i]}" -gt 0 ]]; then
            ROLLBACK_ACTIVE_RS="${RS_NAMES[$i]}"
            ROLLBACK_ACTIVE_TIME="${RS_TIMES[$i]}"
            break
        fi
    done

    # If the newest RS (by creation time) has 0 replicas and was created within the time window,
    # while an older RS is active, this strongly indicates a rollback
    if [[ "$NEWEST_RS_REPLICAS" == "0" && -n "$ROLLBACK_ACTIVE_RS" && "$ROLLBACK_ACTIVE_RS" != "$NEWEST_RS_NAME" ]]; then
        if [[ "$NEWEST_RS_TIME" > "$CUTOFF_TIME" ]]; then
            ROLLBACK_PATTERN_DETECTED=true
            ROLLBACK_NEWEST_RS="$NEWEST_RS_NAME"
        fi
    fi
fi

if [[ "$ROLLBACK_PATTERN_DETECTED" == "true" || -n "$ROLLBACK_EVENT_DETAILS" ]]; then
    echo "⚠️ Rollback Detected for deployment $DEPLOYMENT_NAME"

    if [[ -n "$ROLLBACK_EVENT_DETAILS" ]]; then
        echo "Rollback events found:"
        echo "$ROLLBACK_EVENT_DETAILS"
    fi

    if [[ "$ROLLBACK_PATTERN_DETECTED" == "true" ]]; then
        echo "Rollback pattern detected in ReplicaSet history:"
        echo "  Recently created ReplicaSet (now scaled down): $ROLLBACK_NEWEST_RS (created: $NEWEST_RS_TIME, replicas: $NEWEST_RS_REPLICAS)"
        echo "  Currently active ReplicaSet (rolled back to): $ROLLBACK_ACTIVE_RS (created: $ROLLBACK_ACTIVE_TIME)"
        echo "  The deployment was updated but then rolled back. The failed update created $ROLLBACK_NEWEST_RS which is now inactive."
    fi
else
    echo "✅ No rollback detected within $TIME_WINDOW"
fi

echo
echo "=== kubectl apply Status ==="

# Check for recent kubectl apply operations
DEPLOYMENT_JSON=$(${KUBERNETES_DISTRIBUTION_BINARY} get deployment "$DEPLOYMENT_NAME" --context "$CONTEXT" -n "$NAMESPACE" -o json)

# Check for last-applied-configuration annotation
LAST_APPLIED=$(echo "$DEPLOYMENT_JSON" | jq -r '.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"] // "null"')

if [[ "$LAST_APPLIED" != "null" ]]; then
    echo "✅ kubectl apply annotation found"
    
    # Check generation vs observedGeneration
    GENERATION=$(echo "$DEPLOYMENT_JSON" | jq -r '.metadata.generation // 0')
    OBSERVED_GENERATION=$(echo "$DEPLOYMENT_JSON" | jq -r '.status.observedGeneration // 0')
    
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
echo "ℹ️  Configuration drift occurs when a resource's desired state (spec) has been modified"
echo "   but the controller hasn't finished processing those changes yet."
echo

GENERATION=$(echo "$DEPLOYMENT_JSON" | jq -r '.metadata.generation // 0')
OBSERVED_GENERATION=$(echo "$DEPLOYMENT_JSON" | jq -r '.status.observedGeneration // 0')

echo "📋 Generation Analysis:"
echo "  • metadata.generation: $GENERATION (desired state version)"
echo "  • status.observedGeneration: $OBSERVED_GENERATION (controller's processed version)"

if [[ "$GENERATION" -gt "$OBSERVED_GENERATION" ]]; then
    DRIFT_AMOUNT=$((GENERATION - OBSERVED_GENERATION))
    echo "⚠️  Configuration drift detected: $DRIFT_AMOUNT generation(s) ahead"
    echo "   This means the deployment spec has been updated $DRIFT_AMOUNT time(s) but the"
    echo "   controller hasn't finished processing all changes yet."
    echo
    echo "🔍 Possible causes:"
    echo "  • Recent kubectl apply/patch operations"
    echo "  • Resource constraints preventing rollout"
    echo "  • Controller processing delays"
    echo "  • Failed rollout conditions"
    
    # Check deployment conditions for more context
    CONDITIONS=$(echo "$DEPLOYMENT_JSON" | jq -r '.status.conditions[]? | "  • \(.type): \(.status) - \(.reason // "N/A") (\(.lastUpdateTime // .lastTransitionTime // "unknown"))"' | head -5)
    if [[ -n "$CONDITIONS" ]]; then
        echo
        echo "📊 Current deployment conditions:"
        echo "$CONDITIONS"
    fi
else
    echo "✅ No configuration drift detected"
    echo "   The controller has processed all configuration changes."
fi

echo
echo "=== Summary ==="
echo "Analysis completed for deployment $DEPLOYMENT_NAME in namespace $NAMESPACE"
echo "Current ReplicaSet: $CURRENT_RS"
echo "ReplicaSet created: $CURRENT_TIME"

# Format timestamp for display
FORMATTED_TIME=$(date -d "$CURRENT_TIME" "+%Y-%m-%d %H:%M:%S UTC" 2>/dev/null || echo "$CURRENT_TIME")
echo "Last change time: $FORMATTED_TIME"
