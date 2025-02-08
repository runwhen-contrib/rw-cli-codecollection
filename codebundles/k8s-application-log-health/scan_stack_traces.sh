#!/bin/bash

# NAMESPACE=$1
# WORKLOAD_TYPE=$2
# WORKLOAD_NAME=$3
# CONTEXT=${5:-default}
LOG_LINES=${4:-1000}
ERROR_JSON="error_patterns.json"

ISSUES_OUTPUT=${OUTPUT_DIR}/scan_stacktrace_issues.json

ISSUES_JSON='{"issues": []}'

echo "Scanning logs for stack traces in ${WORKLOAD_TYPE}/${WORKLOAD_NAME} in namespace ${NAMESPACE}..."
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

        # Detect stack traces across multiple languages
        awk '
            /Exception|Traceback|panic:|^Caused by:/ { capture=1; print; next }
            /^\s+at\s+/ && capture { print; next }
            /^\s+File\s+".*",\s+line\s+\d+/ && capture { print; next }
            /^\s+[a-zA-Z0-9_]+(\.[a-zA-Z0-9_]+)*\(/ && capture { print; next }
            /^\s+at\s+\S+:\d+:\d+/ && capture { print; next }
            /segmentation fault|core dumped/ { capture=1; print; next }
            /^\s+at\s+\S+\s+\(.*:\d+:\d+\)$/ && capture { print; next }
            /^$/ { capture=0 }
        ' "${LOG_FILE}" > "${TRACE_FILE}" 2>/dev/null

        # If stack traces were found, process them
        if [[ -s "${TRACE_FILE}" ]]; then
            DETAILS=$(jq -Rs . < "${TRACE_FILE}")

            # Determine stack trace category (language)
            MATCHED_PATTERN=""
            NEXT_STEP=""
            SEVERITY=""

            while read -r pattern; do
                if grep -qEi "${pattern}" "${TRACE_FILE}"; then
                    MATCHED_PATTERN="${pattern}"
                    CATEGORY=$(jq -r --arg pattern "${pattern}" '.patterns[] | select(.match == $pattern) | .category' "${ERROR_JSON}")
                    SEVERITY=$(jq -r --arg pattern "${pattern}" '.patterns[] | select(.match == $pattern) | .severity' "${ERROR_JSON}")
                    NEXT_STEP=$(jq -r --arg pattern "${pattern}" '.patterns[] | select(.match == $pattern) | .next_step' "${ERROR_JSON}")
                    break
                fi
            done < <(jq -r '.patterns[] | select(.category == "Exceptions") | .match' "${ERROR_JSON}")

            # If no specific match was found, set a generic message
            if [[ -z "${NEXT_STEP}" ]]; then
                NEXT_STEP="Investigate the stack trace. Identify the root cause and debug accordingly."
                SEVERITY=3
            fi

            ISSUES_JSON=$(echo "$ISSUES_JSON" | jq \
                --arg title "Stack Trace Detected in ${POD} (${CONTAINER}) - ${CATEGORY}" \
                --arg details "${DETAILS}" \
                --arg nextStep "${NEXT_STEP}" \
                --arg severity "${SEVERITY}" \
                '.issues += [{"title": $title, "details": $details, "next_step": $nextStep, "severity": ($severity | tonumber)}]'
            )
        fi
    done
done

echo "${ISSUES_JSON}" > $ISSUES_OUTPUT

