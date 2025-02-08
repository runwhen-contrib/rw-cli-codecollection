#!/bin/bash

# NAMESPACE=$1
# WORKLOAD_TYPE=$2
# WORKLOAD_NAME=$3
# CONTEXT=${5:-default}
LOG_LINES=${4:-500}
ERROR_JSON="error_patterns.json"


ISSUES_JSON='{"issues": []}'
ISSUES_OUTPUT=${OUTPUT_DIR}/scan_exception_issues.json
ERROR_COUNTS=()
declare -A ERROR_STATS

echo "Scanning logs for null pointer and unhandled exceptions in ${WORKLOAD_TYPE}/${WORKLOAD_NAME} in namespace ${NAMESPACE}..."
PODS=($(jq -r '.[].metadata.name' "${OUTPUT_DIR}/application_logs_pods.json"))

for POD in ${PODS[@]}; do
    echo "Processing Pod $POD"
    CONTAINERS=$(kubectl get pod "${POD}" -n "${NAMESPACE}" --context "${CONTEXT}" -o jsonpath='{.spec.containers[*].name}')
    
    for CONTAINER in ${CONTAINERS}; do
        LOG_FILE="${OUTPUT_DIR}/${POD}_${CONTAINER}_logs.txt"
        ERROR_FILE="${OUTPUT_DIR}/${POD}_${CONTAINER}_exceptions.txt"
        
        kubectl logs "${POD}" -c "${CONTAINER}" -n "${NAMESPACE}" --context "${CONTEXT}" --tail="${LOG_LINES}" --timestamps > "${LOG_FILE}" 2>/dev/null
        kubectl logs "${POD}" -c "${CONTAINER}" -n "${NAMESPACE}" --context "${CONTEXT}" --tail="${LOG_LINES}" --timestamps --previous >> "${LOG_FILE}" 2>/dev/null

        declare -A ERROR_AGGREGATE

        while read -r pattern; do
            MATCHED_LINES=$(grep -Ei "${pattern}" "${LOG_FILE}" || true)
            if [[ -n "${MATCHED_LINES}" ]]; then
                CATEGORY=$(jq -r --arg pattern "${pattern}" '.patterns[] | select(.match == $pattern) | .category' "${ERROR_JSON}")
                SEVERITY=$(jq -r --arg pattern "${pattern}" '.patterns[] | select(.match == $pattern) | .severity' "${ERROR_JSON}")
                NEXT_STEP=$(jq -r --arg pattern "${pattern}" '.patterns[] | select(.match == $pattern) | .next_step' "${ERROR_JSON}")

                NEXT_STEP="${NEXT_STEP//\$\{WORKLOAD_TYPE\}/${WORKLOAD_TYPE}}"
                NEXT_STEP="${NEXT_STEP//\$\{WORKLOAD_NAME\}/${WORKLOAD_NAME}}"

                if [[ -v ERROR_AGGREGATE["$pattern"] ]]; then
                    ERROR_AGGREGATE["$pattern"]+=$'\n'"${MATCHED_LINES}"
                else
                    ERROR_AGGREGATE["$pattern"]="${MATCHED_LINES}"
                fi
                
                ERROR_COUNTS+=("$CATEGORY")

                # Count occurrences
                if [[ -v ERROR_STATS["$pattern"] ]]; then
                    ((ERROR_STATS["$pattern"]++))
                else
                    ERROR_STATS["$pattern"]=1
                fi
            fi
        done < <(jq -r '.patterns[].match' "${ERROR_JSON}")

        for pattern in "${!ERROR_AGGREGATE[@]}"; do
            DETAILS=$(jq -Rs . <<< "${ERROR_AGGREGATE[$pattern]}")

            CATEGORY=$(jq -r --arg pattern "$pattern" '.patterns[] | select(.match == $pattern) | .category' "${ERROR_JSON}")
            SEVERITY=$(jq -r --arg pattern "$pattern" '.patterns[] | select(.match == $pattern) | .severity' "${ERROR_JSON}")
            NEXT_STEP=$(jq -r --arg pattern "$pattern" '.patterns[] | select(.match == $pattern) | .next_step' "${ERROR_JSON}")

            NEXT_STEP="${NEXT_STEP//\$\{WORKLOAD_TYPE\}/${WORKLOAD_TYPE}}"
            NEXT_STEP="${NEXT_STEP//\$\{WORKLOAD_NAME\}/${WORKLOAD_NAME}}"

            ISSUES_JSON=$(echo "$ISSUES_JSON" | jq \
                --arg title "Unhandled Exception Detected in ${POD} (${CONTAINER}) - ${CATEGORY}" \
                --arg details "${DETAILS}" \
                --arg nextStep "${NEXT_STEP}" \
                --arg severity "${SEVERITY}" \
                '.issues += [{"title": $title, "details": $details, "next_step": $nextStep, "severity": ($severity | tonumber)}]'
            )
        done
    done
done

# Generate summary
UNIQUE_CATEGORIES=$(printf "%s\n" "${ERROR_COUNTS[@]}" | sort -u | paste -sd ", ")
SUMMARY=${UNIQUE_CATEGORIES:+"Detected unhandled exceptions affecting ${UNIQUE_CATEGORIES}."}
SUMMARY=${SUMMARY:-"No unhandled exceptions detected."}

ISSUES_JSON=$(echo "$ISSUES_JSON" | jq --arg summary "$SUMMARY" '.summary = $summary')

echo "${ISSUES_JSON}" > $ISSUES_OUTPUT

