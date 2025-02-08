#!/bin/bash

# NAMESPACE=$1
# WORKLOAD_TYPE=$2
# WORKLOAD_NAME=$3
# CONTEXT=${5:-default}

LOG_LINES=${4:-500}

ERROR_JSON="error_patterns.json"

ISSUES_JSON='{"issues": []}'
ISSUES_OUTPUT=${OUTPUT_DIR}/scan_auth_issues.json
ERROR_COUNTS=()
declare -A ERROR_STATS

echo "Scanning logs for authentication and authorization failures in ${WORKLOAD_TYPE}/${WORKLOAD_NAME} in namespace ${NAMESPACE}..."
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

        declare -A ERROR_AGGREGATE

        while read -r pattern; do
            MATCHED_LINES=$(grep -Pi "${pattern}" "${LOG_FILE}" || true)
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
        done < <(jq -r '.patterns[] | select(.category == "Auth") | .match' "${ERROR_JSON}")

        for pattern in "${!ERROR_AGGREGATE[@]}"; do
            DETAILS=$(jq -Rs . <<< "${ERROR_AGGREGATE[$pattern]}")

            CATEGORY=$(jq -r --arg pattern "$pattern" '.patterns[] | select(.match == $pattern) | .category' "${ERROR_JSON}")
            SEVERITY=$(jq -r --arg pattern "$pattern" '.patterns[] | select(.match == $pattern) | .severity' "${ERROR_JSON}")
            NEXT_STEP=$(jq -r --arg pattern "$pattern" '.patterns[] | select(.match == $pattern) | .next_step' "${ERROR_JSON}")

            NEXT_STEP="${NEXT_STEP//\$\{WORKLOAD_TYPE\}/${WORKLOAD_TYPE}}"
            NEXT_STEP="${NEXT_STEP//\$\{WORKLOAD_NAME\}/${WORKLOAD_NAME}}"

            # Adjust recommendations based on occurrence severity
            OCCURRENCES=${ERROR_STATS["$pattern"]}
            if ((OCCURRENCES >= 10)); then
                NEXT_STEP+=" Multiple failures detected (${OCCURRENCES} occurrences). Immediate security review recommended."
                SEVERITY=1
            elif ((OCCURRENCES >= 5)); then
                NEXT_STEP+=" Repeated failures detected (${OCCURRENCES} occurrences). Consider increasing security logging and monitoring."
                SEVERITY=2
            fi

            ISSUES_JSON=$(echo "$ISSUES_JSON" | jq \
                --arg title "Authentication/Authorization Failure in ${POD} (${CONTAINER}) - ${CATEGORY}" \
                --arg details "${DETAILS}" \
                --arg nextStep "${NEXT_STEP}" \
                --arg severity "${SEVERITY}" \
                --arg occurrences "$OCCURRENCES" \
                '.issues += [{"title": $title, "details": $details, "next_step": $nextStep, "severity": ($severity | tonumber), "occurrences": ($occurrences | tonumber)}]'
            )
        done
    done
done

# Generate summary of affected services
if [[ ${#ERROR_COUNTS[@]} -gt 0 ]]; then
    UNIQUE_CATEGORIES=$(printf "%s\n" "${ERROR_COUNTS[@]}" | sort -u | paste -sd ", ")
    SUMMARY="Detected authentication and authorization issues affecting ${UNIQUE_CATEGORIES}."
else
    SUMMARY="No authentication or authorization failures detected."
fi

ISSUES_JSON=$(echo "$ISSUES_JSON" | jq --arg summary "$SUMMARY" '.summary = $summary')

echo "${ISSUES_JSON}" > $ISSUES_OUTPUT
