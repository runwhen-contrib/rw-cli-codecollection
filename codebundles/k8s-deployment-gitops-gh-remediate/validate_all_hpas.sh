#!/bin/bash
# -----------------------------------------------------------------------------
# Script Information and Metadata
# -----------------------------------------------------------------------------
# Author: @jon-funk
# Description: This script takes a namespace and iterates over all HorizontalPodAutoscalers, checking for scaling issues or events.
# -----------------------------------------------------------------------------


NAMESPACE="${1}"

declare -a remediation_steps=()
declare -a next_steps=()

# Function to extract data using jq
extract_data() {
    echo "$1" | jq -r "$2" 2>/dev/null
}

HPA_OBJECTS=$(${KUBERNETES_DISTRIBUTION_BINARY} get HorizontalPodAutoscalers -n "$NAMESPACE" --context "$CONTEXT" -o json)
if [ $? -ne 0 ]; then
    echo "Error fetching $OBJECT_TYPE details: $OBJECTS"
    exit 1
fi

# Get number of objects
NUM_OBJECTS=$(extract_data "$HPA_OBJECTS" '.items | length')
if [ -z "$NUM_OBJECTS" ]; then
    echo "No $OBJECT_TYPE found in namespace $NAMESPACE."
    exit 1
fi

# Loop through each object
for ((o=0; o<NUM_OBJECTS; o++)); do
    OBJECT_NAME=$(extract_data "$HPA_OBJECTS" ".items[$o].metadata.name")
    MANIFEST=$(extract_data "$HPA_OBJECTS" ".items[$o]")
    MAX_REPLICAS=$(extract_data "$HPA_OBJECTS" ".items[$o].spec.maxReplicas")
    NEW_MAX_REPLICAS=$MAX_REPLICAS+1

    STATUSES=$(extract_data "$HPA_OBJECTS" ".items[$o].status")
    HAS_TOO_MANY_REPLICAS=$(extract_data "$STATUSES" ".status.conditions[] | select(.reason == \"TooManyReplicas\") // \"NO\"")
    if [[ "$HAS_TOO_MANY_REPLICAS" != "NO" ]]; then
        HAS_TOO_MANY_REPLICAS="YES"
        next_steps+=("Increase the max replicas for \`HorizontalPodAutoscaler/${OBJECT_NAME}\` from ${MAX_REPLICAS} to ${NEW_MAX_REPLICAS}")
        remediation_steps+=("{\"remediation_type\":\"increase_hpa_replicas\",\"object_type\":\"HorizontalPodAutoscaler\",\"object_name\":\"$OBJECT_NAME\"")
    fi

    METRICS=$(extract_data "$HPA_OBJECTS" ".items[$o].spec.metrics")
    METRIC_NAME=$(extract_data "$METRICS" ".[0].resource.name")
    METRIC_TARGET=$(extract_data "$METRICS" ".[0].resource.target")
    METRIC_UTIL_VALUE=$(extract_data "$METRICS" ".[0].resource.target.averageUtilization")

    TARET_REF=$(extract_data "$HPA_OBJECTS" ".items[$o].spec.scaleTargetRef")
    TARGET_KIND=$(extract_data "$TARGET_REF" ".kind")
    TARGET_NAME=$(extract_data "$TARGET_REF" ".name")

    echo "-------- START Validation -------"
    echo "Object: HorizontalPodAutoscaler/$OBJECT_NAME"
    echo "Metric Name: $METRIC_NAME"
    echo "Metric Target: $METRIC_TARGET"
    echo "Scale Target Name: $TARGET_NAME"
    echo "Scale Target Kind: $TARGET_KIND"
    echo "Has Limited Scaling: $HAS_TOO_MANY_REPLICAS"
    echo "------- END Validation -------"
    echo ""
done

# Display all unique recommendations that can be shown as Next Steps
if [[ ${#next_steps[@]} -ne 0 ]]; then
    printf "\nRecommended Next Steps: \n"
    printf "%s\n" "${next_steps[@]}" | sort -u
fi

REMEDIATION_STEPS_JSON=$(printf '%s\n' "${remediation_steps[@]}" | jq -s .)
echo ""
echo "Remediation Steps:"
echo "$REMEDIATION_STEPS_JSON"