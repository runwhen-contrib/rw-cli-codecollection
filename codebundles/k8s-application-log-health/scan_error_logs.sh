#!/bin/bash

# NAMESPACE=$1
# WORKLOAD_TYPE=$2
# WORKLOAD_NAME=$3
# CONTEXT=${5:-default}
LOG_LINES=${4:-500}  # Default to last 500 lines if not specified

ERROR_JSON="error_patterns.json"
ISSUES_OUTPUT=${OUTPUT_DIR}/scan_error_issues.json
ISSUES_JSON='{"issues": []}'

echo "Scanning logs for errors in ${WORKLOAD_TYPE}/${WORKLOAD_NAME} in namespace ${NAMESPACE}..."
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

        # Scan logs for all known error patterns
        while read -r pattern; do
            MATCHED_LINES=$(grep -Pi "${pattern}" "${LOG_FILE}" || true)
            if [[ -n "${MATCHED_LINES}" ]]; then
                echo "Matches:"
                echo "${MATCHED_LINES}"
                DETAILS=$(jq -Rs . <<< "${MATCHED_LINES}")
                CATEGORY=$(jq -r --arg pattern "${pattern}" '.patterns[] | select(.match == $pattern) | .category' "${ERROR_JSON}")
                SEVERITY=$(jq -r --arg pattern "${pattern}" '.patterns[] | select(.match == $pattern) | .severity' "${ERROR_JSON}")
                NEXT_STEP=$(jq -r --arg pattern "${pattern}" '.patterns[] | select(.match == $pattern) | .next_step' "${ERROR_JSON}")

                ISSUES_JSON=$(echo "$ISSUES_JSON" | jq \
                    --arg title "Errors detected in ${POD} (${CONTAINER}) - ${CATEGORY}" \
                    --arg details "${DETAILS}" \
                    --arg nextStep "${NEXT_STEP}" \
                    --arg severity "${SEVERITY}" \
                    '.issues += [{"title": $title, "details": $details, "next_step": $nextStep, "severity": ($severity | tonumber)}]'
                )
            fi
        done < <(jq -r '.patterns[] | select(.category == "GenericError" or .category == "AppFailure") | .match' "${ERROR_JSON}")
    done
done

echo "${ISSUES_JSON}" > $ISSUES_OUTPUT

