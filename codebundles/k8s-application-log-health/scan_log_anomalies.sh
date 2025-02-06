#!/bin/bash

# NAMESPACE=$1
# WORKLOAD_TYPE=$2
# WORKLOAD_NAME=$3
# CONTEXT=${5:-default}
LOG_LINES=${4:-1000}  # Fetch more lines to detect patterns

ERROR_JSON="../error_patterns.json"
ISSUES_OUTPUT=${OUTPUT_DIR}/scan_anomoly_issues.json
ISSUES_JSON='{"issues": []}'

echo "Scanning logs for frequent log anomalies in ${WORKLOAD_TYPE}/${WORKLOAD_NAME} in namespace ${NAMESPACE}..."
PODS=($(jq -r '.[].metadata.name' "${OUTPUT_DIR}/application_logs_pods.json"))

for POD in ${PODS[@]}; do
    CONTAINERS=$(kubectl get pod "${POD}" -n "${NAMESPACE}" --context "${CONTEXT}" -o jsonpath='{.spec.containers[*].name}')
    
    for CONTAINER in ${CONTAINERS}; do
        LOG_FILE="${OUTPUT_DIR}/${POD}_${CONTAINER}_logs.txt"
        ANOMALY_FILE="${OUTPUT_DIR}/${POD}_${CONTAINER}_log_anomalies.txt"
        
        kubectl logs "${POD}" -c "${CONTAINER}" -n "${NAMESPACE}" --context "${CONTEXT}" --tail="${LOG_LINES}" --timestamps > "${LOG_FILE}" 2>/dev/null
        kubectl logs "${POD}" -c "${CONTAINER}" -n "${NAMESPACE}" --context "${CONTEXT}" --tail="${LOG_LINES}" --timestamps --previous >> "${LOG_FILE}" 2>/dev/null

        # Count occurrences of repeating log messages
        awk '{count[$0]++} END {for (line in count) if (count[line] > 1) print count[line], line}' "${LOG_FILE}" | sort -nr > "${ANOMALY_FILE}"

        while read -r count message; do
            SEVERITY=3  # Default to informational
            NEXT_STEP="Review logs in ${WORKLOAD_TYPE} ${WORKLOAD_NAME} to determine if frequent messages indicate an issue."

            if (( count >= 10 )); then
                SEVERITY=1
                NEXT_STEP="Critical: High volume of repeated log messages detected (${count} occurrences). Immediate investigation recommended."
            elif (( count >= 5 )); then
                SEVERITY=2
                NEXT_STEP="Warning: Repeated log messages detected (${count} occurrences). Investigate potential issues."

            fi

            DETAILS=$(jq -Rs . <<< "${message}")

            ISSUES_JSON=$(echo "$ISSUES_JSON" | jq \
                --arg title "Frequent Log Anomaly Detected in ${POD} (${CONTAINER})" \
                --arg details "${DETAILS}" \
                --arg nextStep "${NEXT_STEP}" \
                --arg severity "${SEVERITY}" \
                --arg occurrences "$count" \
                '.issues += [{"title": $title, "details": $details, "next_step": $nextStep, "severity": ($severity | tonumber), "occurrences": ($occurrences | tonumber)}]'
            )
        done < "${ANOMALY_FILE}"
    done
done

# Generate summary
TOTAL_ANOMALIES=$(jq '.issues | length' <<< "$ISSUES_JSON")
SUMMARY="Detected ${TOTAL_ANOMALIES} log anomalies across pods in ${WORKLOAD_TYPE} ${WORKLOAD_NAME}."

ISSUES_JSON=$(echo "$ISSUES_JSON" | jq --arg summary "$SUMMARY" '.summary = $summary')

echo "${ISSUES_JSON}" > $ISSUES_OUTPUT

