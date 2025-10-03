#!/bin/bash

# Track StatefulSet configuration changes by analyzing ControllerRevisions
# This script provides configuration change analysis for StatefulSets

# Function to extract timestamp from log line, fallback to current time
extract_log_timestamp() {
    local log_line="$1"
    local fallback_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    if [[ -z "$log_line" ]]; then
        echo "$fallback_timestamp"
        return
    fi
    
    # Try to extract common timestamp patterns
    # ISO 8601 format: 2024-01-15T10:30:45.123Z
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z?) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Standard log format: 2024-01-15 10:30:45
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        # Convert to ISO format
        local extracted_time="${BASH_REMATCH[1]}"
        local iso_time=$(date -d "$extracted_time" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # DD-MM-YYYY HH:MM:SS format
    if [[ "$log_line" =~ ([0-9]{2}-[0-9]{2}-[0-9]{4}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        local extracted_time="${BASH_REMATCH[1]}"
        # Convert DD-MM-YYYY to YYYY-MM-DD for date parsing
        local day=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f1)
        local month=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f2)
        local year=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f3)
        local time_part=$(echo "$extracted_time" | cut -d' ' -f2)
        local iso_time=$(date -d "$year-$month-$day $time_part" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # Fallback to current timestamp
    echo "$fallback_timestamp"
}

set -eo pipefail

# Required parameters
STATEFULSET_NAME="${1:-}"
NAMESPACE="${2:-}"
CONTEXT="${3:-}"
TIME_WINDOW="${4:-24h}"

if [[ -z "$STATEFULSET_NAME" || -z "$NAMESPACE" || -z "$CONTEXT" ]]; then
    echo "Usage: $0 <statefulset_name> <namespace> <context> [time_window]"
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

echo "=== StatefulSet Configuration Change Analysis ==="
echo "StatefulSet: $STATEFULSET_NAME"
echo "Namespace: $NAMESPACE" 
echo "Context: $CONTEXT"
echo "Time Window: $TIME_WINDOW (since $CUTOFF_TIME)"
echo

# Check if StatefulSet exists
if ! ${KUBERNETES_DISTRIBUTION_BINARY} get statefulset "$STATEFULSET_NAME" --context "$CONTEXT" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "ERROR: StatefulSet '$STATEFULSET_NAME' not found in namespace '$NAMESPACE' with context '$CONTEXT'"
    exit 0  # Exit gracefully like other tasks
fi

# Get ControllerRevisions owned by this StatefulSet, sorted by creation time (newest first)
echo "=== ControllerRevision Analysis ==="
REVISIONS=$(${KUBERNETES_DISTRIBUTION_BINARY} get controllerrevisions --context "$CONTEXT" -n "$NAMESPACE" -o json | \
    jq -r --arg statefulset "$STATEFULSET_NAME" '
    [.items[] | select(
        .metadata.ownerReferences[]? | 
        select(.kind == "StatefulSet" and .name == $statefulset)
    )] | 
    sort_by(.metadata.creationTimestamp) | 
    reverse | 
    .[] | 
    "\(.metadata.name)|\(.metadata.creationTimestamp)|\(.revision // 0)"
')

if [[ -z "$REVISIONS" ]]; then
    echo "No ControllerRevisions found for StatefulSet $STATEFULSET_NAME"
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
        
        # Compare pod template (StatefulSet spec)
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
            
            # Compare resource requirements
            CURRENT_RESOURCES=$(echo "$CURRENT_TEMPLATE" | jq -c '.spec.containers[]? | {name: .name, resources: .resources}')
            PREVIOUS_RESOURCES=$(echo "$PREVIOUS_TEMPLATE" | jq -c '.spec.containers[]? | {name: .name, resources: .resources}')
            
            if [[ "$CURRENT_RESOURCES" != "$PREVIOUS_RESOURCES" ]]; then
                echo "📊 Resource Requirement Changes Detected"
                echo
            fi
        fi
        
        # Compare volume claim templates (CRITICAL for StatefulSets)
        CURRENT_VCT=$(echo "$CURRENT_DATA" | jq '.spec.volumeClaimTemplates // []')
        PREVIOUS_VCT=$(echo "$PREVIOUS_DATA" | jq '.spec.volumeClaimTemplates // []')
        
        if [[ "$CURRENT_VCT" != "$PREVIOUS_VCT" ]]; then
            echo "🚨 CRITICAL: Volume Claim Template Changes Detected!"
            echo "⚠️  WARNING: This is a critical change for StatefulSets that can affect data persistence!"
            echo "Previous volume claim templates:"
            echo "$PREVIOUS_VCT" | jq -r '.[] | "  - \(.metadata.name): \(.spec.resources.requests.storage // "unknown") (\(.spec.storageClassName // "default"))"'
            echo "Current volume claim templates:"
            echo "$CURRENT_VCT" | jq -r '.[] | "  - \(.metadata.name): \(.spec.resources.requests.storage // "unknown") (\(.spec.storageClassName // "default"))"'
            echo
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
STATEFULSET_JSON=$(${KUBERNETES_DISTRIBUTION_BINARY} get statefulset "$STATEFULSET_NAME" --context "$CONTEXT" -n "$NAMESPACE" -o json)

# Check for last-applied-configuration annotation
LAST_APPLIED=$(echo "$STATEFULSET_JSON" | jq -r '.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"] // "null"')

if [[ "$LAST_APPLIED" != "null" ]]; then
    echo "✅ kubectl apply annotation found"
    
    # Check generation vs observedGeneration
    GENERATION=$(echo "$STATEFULSET_JSON" | jq -r '.metadata.generation // 0')
    OBSERVED_GENERATION=$(echo "$STATEFULSET_JSON" | jq -r '.status.observedGeneration // 0')
    
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

GENERATION=$(echo "$STATEFULSET_JSON" | jq -r '.metadata.generation // 0')
OBSERVED_GENERATION=$(echo "$STATEFULSET_JSON" | jq -r '.status.observedGeneration // 0')

if [[ "$GENERATION" -gt "$OBSERVED_GENERATION" ]]; then
    DRIFT_AMOUNT=$((GENERATION - OBSERVED_GENERATION))
    echo "⚠️  Configuration drift detected: $DRIFT_AMOUNT generation(s) ahead"
    echo "The StatefulSet has been modified but the controller hasn't processed all changes yet."
else
    echo "✅ No configuration drift detected"
fi

echo
echo "=== Summary ==="
echo "Analysis completed for StatefulSet $STATEFULSET_NAME in namespace $NAMESPACE"
echo "Current ControllerRevision: $CURRENT_REV (revision: $CURRENT_REV_NUM)"
echo "ControllerRevision created: $CURRENT_TIME"

# Format timestamp for display
FORMATTED_TIME=$(date -d "$CURRENT_TIME" "+%Y-%m-%d %H:%M:%S UTC" 2>/dev/null || echo "$CURRENT_TIME")
echo "Last change time: $FORMATTED_TIME"
echo
echo "⚠️  Note: StatefulSets use ControllerRevisions to track configuration changes and update pods sequentially."
