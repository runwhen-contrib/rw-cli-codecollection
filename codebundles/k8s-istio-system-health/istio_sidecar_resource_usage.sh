#!/bin/bash

# Print table headers for pods with limits
printf "%-15s %-40s %-15s %-15s %-15s %-15s %-15s %-15s\n" \
    "Namespace" "Pod" "CPU_Limits(m)" "CPU_Usage(m)" "CPU_Usage(%)" "Mem_Limits(Mi)" "Mem_Usage(Mi)" "Mem_Usage(%)"
echo "-----------------------------------------------------------------------------------------------------------------------------------------------------"

# Get all namespaces
NAMESPACES=$(${KUBERNETES_DISTRIBUTION_BINARY} get namespaces --context="${CONTEXT}" --no-headers -o custom-columns=":metadata.name")

# Separate storage for pods without limits
NO_LIMITS_PODS=()

for NS in $NAMESPACES; do
    # Get all pods in the namespace
    PODS=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n $NS --context="${CONTEXT}" -o jsonpath="{.items[*].metadata.name}")

    for POD in $PODS; do
        # Check if the pod has an istio-proxy container
        CONTAINER_NAMES=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $POD -n $NS --context="${CONTEXT}" -o jsonpath="{.spec.containers[*].name}")

        if echo "$CONTAINER_NAMES" | grep -q "istio-proxy"; then
            # Get CPU limits
            CPU_LIMITS_RAW=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $POD -n $NS --context="${CONTEXT}" -o jsonpath="{.spec.containers[?(@.name=='istio-proxy')].resources.limits.cpu}")
            CPU_LIMITS=$(echo $CPU_LIMITS_RAW | sed 's/m//')

            # If CPU limit is a whole number (not in milliCPU), multiply by 1000
            if [[ "$CPU_LIMITS_RAW" =~ ^[0-9]+$ ]]; then
                CPU_LIMITS=$((CPU_LIMITS * 1000))
            fi

            # Get Memory limits and convert Gi to Mi if needed
            MEM_LIMITS_RAW=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $POD -n $NS --context="${CONTEXT}" -o jsonpath="{.spec.containers[?(@.name=='istio-proxy')].resources.limits.memory}")
            if [[ $MEM_LIMITS_RAW == *Gi ]]; then
                MEM_LIMITS=$(echo $MEM_LIMITS_RAW | sed 's/Gi//')
                MEM_LIMITS=$((MEM_LIMITS * 1024))  # Convert Gi to Mi
            else
                MEM_LIMITS=$(echo $MEM_LIMITS_RAW | sed 's/Mi//')
            fi

            # Get actual CPU & Memory usage
            CPU_USAGE=$(${KUBERNETES_DISTRIBUTION_BINARY} top pod $POD -n $NS --context="${CONTEXT}" --containers | awk '$2 == "istio-proxy" {print $3}' | sed 's/m//')
            MEM_USAGE_RAW=$(${KUBERNETES_DISTRIBUTION_BINARY} top pod $POD -n $NS --context="${CONTEXT}" --containers | awk '$2 == "istio-proxy" {print $4}')

            # Convert Memory usage from Gi to Mi if needed
            if [[ $MEM_USAGE_RAW == *Gi ]]; then
                MEM_USAGE=$(echo $MEM_USAGE_RAW | sed 's/Gi//')
                MEM_USAGE=$((MEM_USAGE * 1024))  # Convert Gi to Mi
            else
                MEM_USAGE=$(echo $MEM_USAGE_RAW | sed 's/Mi//')
            fi

            if [[ -z "$CPU_LIMITS" || -z "$MEM_LIMITS" ]]; then
                # Store pods without limits for separate listing
                NO_LIMITS_PODS+=("$NS $POD")
            else
                # Calculate CPU & Memory usage percentage only if limits exist
                CPU_PERCENTAGE=$(awk "BEGIN {printf \"%.2f\", ($CPU_USAGE * 100) / $CPU_LIMITS}")
                MEM_PERCENTAGE=$(awk "BEGIN {printf \"%.2f\", ($MEM_USAGE * 100) / $MEM_LIMITS}")

                # Print formatted output
                printf "%-15s %-40s %-15s %-15s %-15s %-15s %-15s %-15s\n" \
                    "$NS" "$POD" "$CPU_LIMITS" "$CPU_USAGE" "${CPU_PERCENTAGE}%" "$MEM_LIMITS" "$MEM_USAGE" "${MEM_PERCENTAGE}%"
            fi
        fi
    done
done

# Print pods without limits in a separate section
echo ""
echo "Pods Without Limits:"
echo "----------------------------------------------"

if [ ${#NO_LIMITS_PODS[@]} -eq 0 ]; then
    echo "There are no pods without limits set."
else
    printf "%-15s %-40s\n" "Namespace" "Pod"
    echo "----------------------------------------------"
    for ENTRY in "${NO_LIMITS_PODS[@]}"; do
        printf "%-15s %-40s\n" $ENTRY
    done
fi
