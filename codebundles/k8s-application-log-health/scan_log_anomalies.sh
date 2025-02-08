#!/bin/bash

# NAMESPACE=$1
# WORKLOAD_TYPE=$2
# WORKLOAD_NAME=$3
# CONTEXT=${5:-default}
LOG_LINES=${4:-1000}  # Fetch more lines to detect patterns

ERROR_JSON="error_patterns.json"
ISSUES_OUTPUT=${OUTPUT_DIR}/scan_anomoly_issues.json
ISSUES_JSON='{"issues": []}'

echo "Scanning logs for frequent log anomalies in ${WORKLOAD_TYPE}/${WORKLOAD_NAME} in namespace ${NAMESPACE}..."
PODS=($(jq -r '.[].metadata.name' "${OUTPUT_DIR}/application_logs_pods.json"))

# 2) Iterate over each pod
for POD in "${PODS[@]}"; do
    echo "Processing Pod $POD"

    # 2a) Extract container names from the same JSON
    #     Instead of calling kubectl get pod ...
    CONTAINERS=$(jq -r --arg POD "$POD" '
      .[] 
      | select(.metadata.name == $POD)
      | .spec.containers[].name
    ' "${OUTPUT_DIR}/application_logs_pods.json")

    # 2b) For each container, read the local logs
    for CONTAINER in ${CONTAINERS}; do
        echo "  Processing Container $CONTAINER"
        
        # 3) Point to the local log file from your "get_pods_for_workload_fulljson.sh" step
        LOG_FILE="${OUTPUT_DIR}/${WORKLOAD_TYPE}_${WORKLOAD_NAME}_logs/${POD}_${CONTAINER}_logs.txt"

        if [[ ! -f "$LOG_FILE" ]]; then
            echo "  Warning: No log file found at $LOG_FILE" >&2
            continue
        fi

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

