#!/bin/bash

# Kubernetes Deployment ReplicaSet Management Script
# This script checks Kubernetes deployments to ensure they are running the latest ReplicaSet. It is designed to manage
# ReplicaSets during normal operations and rolling updates, checking for multiple ReplicaSets, verifying the active latest ReplicaSet, and providing actionable insights for any inactive or conflicting ReplicaSets.

# Function to check for rolling update status
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

check_rolling_update_status() {
    # Extract conditions and replica counts
    local progressingCondition=$(echo "$DEPLOYMENT_JSON" | jq '.status.conditions[] | select(.type=="Progressing")')
    local availableCondition=$(echo "$DEPLOYMENT_JSON" | jq '.status.conditions[] | select(.type=="Available").status')
    local replicas=$(echo "$DEPLOYMENT_JSON" | jq '.status.replicas // 0')
    local updatedReplicas=$(echo "$DEPLOYMENT_JSON" | jq '.status.updatedReplicas // 0')
    local availableReplicas=$(echo "$DEPLOYMENT_JSON" | jq '.status.availableReplicas // 0')
    local readyReplicas=$(echo "$DEPLOYMENT_JSON" | jq '.status.readyReplicas // 0')

    # Interpret 'Progressing' condition more accurately
    local progressingStatus=$(echo "$progressingCondition" | jq -r '.status')
    local progressingReason=$(echo "$progressingCondition" | jq -r '.reason')
    local lastUpdateTime=$(echo "$progressingCondition" | jq -r '.lastUpdateTime')

    # Current time in UTC for comparison (assuming 'date' command is available and system timezone is correctly set)
    local currentTime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Compare replica counts for a more accurate ongoing rollout check
    if [[ "$progressingStatus" == "True" && "$progressingReason" == "NewReplicaSetAvailable" && "$updatedReplicas" == "$replicas" && "$availableReplicas" == "$updatedReplicas" && "$readyReplicas" == "$updatedReplicas" ]]; then
        # Check how recent the last update was to consider a buffer for stabilization
        if [[ $(date -d "$lastUpdateTime" +%s) -lt $(date -d "$currentTime" +%s --date='-2 minutes') ]]; then
            echo "Deployment $DEPLOYMENT_NAME is stable. No active rollout detected."
            ROLLING_UPDATE_STATUS=1 # Indicates no update is in progress
        else
            echo "Deployment $DEPLOYMENT_NAME has recently updated and may still be stabilizing."
            ROLLING_UPDATE_STATUS=0 # Indicates recent update, considering stabilization
        fi
    elif [[ "$updatedReplicas" -lt "$replicas" ]] || [[ "$availableReplicas" -lt "$updatedReplicas" ]] || [[ "$readyReplicas" -lt "$updatedReplicas" ]]; then
        echo "Deployment $DEPLOYMENT_NAME is undergoing a rollout."
        ROLLING_UPDATE_STATUS=0 # Indicates an update is in progress
    else
        echo "Deployment $DEPLOYMENT_NAME is stable. No active rollout detected."
        ROLLING_UPDATE_STATUS=1 # Indicates no update is in progress
    fi
}



verify_pods_association_with_latest_rs() {
    # Fetch all pods associated with the deployment
    PODS_JSON=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n $NAMESPACE --context $CONTEXT --selector=app=$DEPLOYMENT_NAME --context $CONTEXT -o json)
    PODS_COUNT=$(echo "$PODS_JSON" | jq '.items | length')
    OUTDATED_PODS_COUNT=0

    for ((i=0; i<PODS_COUNT; i++)); do
        POD_RS=$(echo "$PODS_JSON" | jq -r ".items[$i].metadata.ownerReferences[] | select(.kind == \"ReplicaSet\") | .name")
        if [[ "$POD_RS" != "$LATEST_RS" ]]; then
            OUTDATED_PODS_COUNT=$((OUTDATED_PODS_COUNT + 1))
        fi
    done

    if [[ "$OUTDATED_PODS_COUNT" -eq 0 ]]; then
        echo "All pods are correctly associated with the latest ReplicaSet."
    else
        echo "Warning: $OUTDATED_PODS_COUNT pod(s) are not associated with the latest ReplicaSet."
        issue_details="{\"severity\":\"2\",\"title\":\"$OUTDATED_PODS_COUNT pod(s) are not running the latest version of Deployment \`$DEPLOYMENT_NAME\` in namespace \`${NAMESPACE}\`\",\"next_steps\":\"Clean up stale ReplicaSet \`$RS\` for Deployment \`$DEPLOYMENT_NAME\` in namespace \`${NAMESPACE}\` \",\"details\":\"$RS_DETAILS\"}"
    fi
}

# Get Deployment JSON
DEPLOYMENT_JSON=$(${KUBERNETES_DISTRIBUTION_BINARY} get deployment $DEPLOYMENT_NAME -n $NAMESPACE --context $CONTEXT -o json)

# Get the deployment's latest ReplicaSet
REPLICASETS_JSON=$(${KUBERNETES_DISTRIBUTION_BINARY} get rs -n $NAMESPACE --context $CONTEXT -o json | jq --arg DEPLOYMENT_NAME "$DEPLOYMENT_NAME" \
    '[.items[] | select(.metadata.ownerReferences[]? | select(.kind == "Deployment" and .name == $DEPLOYMENT_NAME))]')

# Extract the name of the latest ReplicaSet from the filtered JSON
LATEST_RS=$(echo "$REPLICASETS_JSON" | jq -r 'sort_by(.metadata.creationTimestamp) | last(.[]).metadata.name')

# Extract names of all ReplicaSets associated with the Deployment from the filtered JSON
ALL_RS=$(echo "$REPLICASETS_JSON" | jq -r '.[].metadata.name' | tr '\n' ' ')
readarray -t ALL_RS_NAMES < <(echo "$REPLICASETS_JSON" | jq -r '.[].metadata.name')

echo "Latest ReplicaSet: $LATEST_RS"
echo "All ReplicaSets for the deployment: $ALL_RS"

ROLLING_UPDATE_STATUS=-1 # Default to -1; will be set to 0 or 1 by check_rolling_update_status
check_rolling_update_status

# Check if there are multiple ReplicaSets and if the latest is active
if [[ $(echo $ALL_RS | tr ' ' '\n' | wc -l) -gt 1 ]]; then
    echo "Multiple ReplicaSets detected. Verifying..."

    # Loop through all ReplicaSets
    for RS in $ALL_RS; do
        # Skip the latest ReplicaSet
        if [[ "$RS" == "$LATEST_RS" ]]; then
            continue
        fi

        # Check the status of older ReplicaSets (replicas, availableReplicas, readyReplicas)
        RS_DETAILS_JSON=$(echo "$REPLICASETS_JSON" | jq --arg RS "$RS" '.[] | select(.metadata.name==$RS)')
        REPLICAS=$(echo "$RS_DETAILS_JSON" | jq '.status.replicas')
        if [[ "$REPLICAS" == "0" ]]; then
            echo "ReplicaSet $RS for Deployment $DEPLOYMENT_NAME is not active. Consider for cleanup..."
        else
            if [[ $ROLLING_UPDATE_STATUS -eq 0 ]]; then
                date
                echo "Multiple ReplicaSets are active, which is expected due to the rolling update process."
                issue_details="{\"severity\":\"4\",\"title\":\"A rolling update is in progress for Deployment \`$DEPLOYMENT_NAME\` in namespace \`${NAMESPACE}\`\",\"next_steps\":\"Wait for Rollout to Complete and Check Again.\",\"details\":\"$RS_DETAILS\"}"
                
            elif [[ $ROLLING_UPDATE_STATUS -eq 1 ]]; then
                echo "Multiple ReplicaSets are active and no update appears to be in place. Investigation may be required to ensure they are not conflicting."
                verify_pods_association_with_latest_rs
                issue_details="{\"severity\":\"2\",\"title\":\"Conflicting versions detected for Deployment \`$DEPLOYMENT_NAME\` in namespace \`${NAMESPACE}\`\",\"next_steps\":\"Clean up stale ReplicaSet \`$RS\` for Deployment \`$DEPLOYMENT_NAME\` in namespace \`${NAMESPACE}\` \",\"details\":\"$RS_DETAILS_JSON\"}"
            else
                echo "Multiple ReplicaSets are active and no update appears to be in place. Investigation may be required to ensure they are not conflicting."
            fi
        fi
    
        # Initialize issues as an empty array if not already set
        if [ -z "$issues" ]; then
            issues="[]"
        fi

        # Concatenate issue detail to the string
        if [ -n "$issue_details" ]; then
            # Remove the closing bracket from issues to prepare for adding a new item
            issues="${issues%]}"

            # If issues is not an empty array (more than just "["), add a comma before the new item
            if [ "$issues" != "[" ]; then
                issues="$issues,"
            fi

            # Add the new issue detail and close the array
            issues="$issues $issue_details]"
        fi
    done
else
    echo "Only one ReplicaSet is active. Deployment is up to date."
fi


# Display all unique recommendations that can be shown as Next Steps
if [ -n "$issues" ]; then
    echo -e "\nRecommended Next Steps: \n"
    echo "$issues"
fi