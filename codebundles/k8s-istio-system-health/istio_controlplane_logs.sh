#!/bin/bash

# Variables
ERROR_JSON="controlplane_error_patterns.json"
ISTIO_NAMESPACES=$(${KUBERNETES_DISTRIBUTION_BINARY} get namespaces --context="${CONTEXT}" --no-headers -o custom-columns=":metadata.name" | grep istio)
ISTIO_COMPONENTS=("istiod" "istio-ingressgateway" "istio-egressgateway")
LOG_DURATION="1h" # Fetch logs from the last 1 hour

# Read error patterns from JSON file
if [[ ! -f "$ERROR_JSON" ]]; then
    echo "❌ Error: JSON file '$ERROR_JSON' not found!"
    exit 1
fi

# Convert JSON into arrays
WARNINGS=($(jq -r '.warnings[]' "$ERROR_JSON"))
ERRORS=($(jq -r '.errors[]' "$ERROR_JSON"))

echo "🔍 Checking Istio Control Plane Logs for Exact Matches..."
echo "-----------------------------------------------------------------------------------------------------------"

FOUND_WARNINGS=false
FOUND_ERRORS=false

for COMPONENT in "${ISTIO_COMPONENTS[@]}"; do
    for NS in $ISTIO_NAMESPACES; do
        # Get all pods for the component
        PODS=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n $NS --context="${CONTEXT}" -l app=$COMPONENT --no-headers -o custom-columns=":metadata.name")

        for POD in $PODS; do
            echo "📜 Checking logs for $POD in namespace $NS..."
            
            # Fetch logs
            LOGS=$(${KUBERNETES_DISTRIBUTION_BINARY} logs $POD -n $NS --context="${CONTEXT}" --since=$LOG_DURATION 2>/dev/null)

            # Check for exact warnings
            for WARNING in "${WARNINGS[@]}"; do
                if echo "$LOGS" | grep -Fx "$WARNING" &>/dev/null; then
                    echo "⚠️ Warning found: '$WARNING' in $POD ($NS)"
                    FOUND_WARNINGS=true
                fi
            done

            # Check for exact errors
            for ERROR in "${ERRORS[@]}"; do
                if echo "$LOGS" | grep -Fx "$ERROR" &>/dev/null; then
                    echo "🚨 Error found: '$ERROR' in $POD ($NS)"
                    FOUND_ERRORS=true
                fi
            done
        done
    done
done

echo "-----------------------------------------------------------------------------------------------------------"

if [ "$FOUND_WARNINGS" = false ] && [ "$FOUND_ERRORS" = false ]; then
    echo "✅ No warnings or errors detected in Istio logs."
else
    echo "⚠️  Some warnings/errors were found in the logs. Please investigate further."
fi
