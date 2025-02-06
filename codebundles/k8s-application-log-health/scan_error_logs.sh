#!/bin/bash

# NAMESPACE=$1
# WORKLOAD_TYPE=$2
# WORKLOAD_NAME=$3
# CONTEXT=${5:-default}
LOG_LINES=${4:-500}  # Default to last 500 lines if not specified

ERROR_JSON="../error_patterns.json"
ISSUES_OUTPUT=${OUTPUT_DIR}/scan_error_issues.json
ISSUES_JSON='{"issues": []}'

echo "Scanning logs for errors in ${WORKLOAD_TYPE}/${WORKLOAD_NAME} in namespace ${NAMESPACE}..."
PODS=($(jq -r '.[].metadata.name' "${OUTPUT_DIR}/application_logs_pods.json"))

for POD in ${PODS[@]}; do
    CONTAINERS=$(kubectl get pod "${POD}" -n "${NAMESPACE}" --context "${CONTEXT}" -o jsonpath='{.spec.containers[*].name}')
    
    for CONTAINER in ${CONTAINERS}; do
        LOG_FILE="${OUTPUT_DIR}/${POD}_${CONTAINER}_logs.txt"
        ERROR_FILE="${OUTPUT_DIR}/${POD}_${CONTAINER}_errors.txt"
        
        # Fetch logs (current + previous)
        kubectl logs "${POD}" -c "${CONTAINER}" -n "${NAMESPACE}" --context "${CONTEXT}" --tail="${LOG_LINES}" --timestamps > "${LOG_FILE}" 2>/dev/null
        kubectl logs "${POD}" -c "${CONTAINER}" -n "${NAMESPACE}" --context "${CONTEXT}" --tail="${LOG_LINES}" --timestamps --previous >> "${LOG_FILE}" 2>/dev/null

        # Scan logs for all known error patterns
        while read -r pattern; do
            MATCHED_LINES=$(grep -Ei "${pattern}" "${LOG_FILE}" || true)
            if [[ -n "${MATCHED_LINES}" ]]; then
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
        done < <(jq -r '.patterns[].match' "${ERROR_JSON}")
    done
done

echo "${ISSUES_JSON}" > $ISSUES_OUTPUT

