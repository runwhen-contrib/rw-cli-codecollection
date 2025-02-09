#!/bin/bash

python3 ${CURDIR}/scan_logs.py


# # NAMESPACE=$1
# # WORKLOAD_TYPE=$2
# # WORKLOAD_NAME=$3
# # CONTEXT=${5:-default}
# LOG_LINES=${4:-1000}  # Fetch more logs to detect patterns
# ERROR_JSON="error_patterns.json"

# ISSUES_JSON='{"issues": []}'
# ISSUES_OUTPUT=${OUTPUT_DIR}/scan_application_restarts.json
# ERROR_COUNTS=()
# declare -A ERROR_STATS
# echo "Scanning logs for application restarts and failures in ${WORKLOAD_TYPE}/${WORKLOAD_NAME} in namespace ${NAMESPACE}..."
# PODS=($(jq -r '.[].metadata.name' "${OUTPUT_DIR}/application_logs_pods.json"))

# # 2) Iterate over each pod
# for POD in "${PODS[@]}"; do
#     echo "Processing Pod $POD"

#     # 2a) Extract container names from the same JSON
#     #     Instead of calling kubectl get pod ...
#     CONTAINERS=$(jq -r --arg POD "$POD" '
#       .[] 
#       | select(.metadata.name == $POD)
#       | .spec.containers[].name
#     ' "${OUTPUT_DIR}/application_logs_pods.json")

#     # 2b) For each container, read the local logs
#     for CONTAINER in ${CONTAINERS}; do
#         echo "  Processing Container $CONTAINER"
        
#         # 3) Point to the local log file from your "get_pods_for_workload_fulljson.sh" step
#         LOG_FILE="${OUTPUT_DIR}/${WORKLOAD_TYPE}_${WORKLOAD_NAME}_logs/${POD}_${CONTAINER}_logs.txt"

#         if [[ ! -f "$LOG_FILE" ]]; then
#             echo "  Warning: No log file found at $LOG_FILE" >&2
#             continue
#         fi

#         declare -A ERROR_AGGREGATE

#         while read -r pattern; do
#            MATCHED_LINES=$(grep -Pi "${pattern}" "${LOG_FILE}" || true)
#             if [[ -n "${MATCHED_LINES}" ]]; then
#                 # Lookup metadata from error_patterns.json
#                 CATEGORY=$(jq -r --arg pattern "${pattern}" '
#                   .patterns[] | select(.match == $pattern) | .category
#                 ' "${ERROR_JSON}")

#                 SEVERITY=$(jq -r --arg pattern "${pattern}" '
#                   .patterns[] | select(.match == $pattern) | .severity
#                 ' "${ERROR_JSON}")

#                 NEXT_STEP=$(jq -r --arg pattern "${pattern}" '
#                   .patterns[] | select(.match == $pattern) | .next_steps
#                 ' "${ERROR_JSON}")

#                 # Replace placeholders in next steps
#                 NEXT_STEP="${NEXT_STEP//\$\{WORKLOAD_TYPE\}/${WORKLOAD_TYPE}}"
#                 NEXT_STEP="${NEXT_STEP//\$\{WORKLOAD_NAME\}/\`${WORKLOAD_NAME}\`}"
#                 NEXT_STEP="${NEXT_STEP//\$\{NAMESPACE\}/\`${NAMESPACE}\`}"

#                 # Append these matched lines into aggregator for this container
#                 aggregator["$CONTAINER"]+=$'\n'
#                 aggregator["$CONTAINER"]+="--- Pod: $POD (pattern: $pattern) ---\n${MATCHED_LINES}\n"

#                 # Add next steps to our global list
#                 # (We'll deduplicate later)
#                 all_next_steps+=("$NEXT_STEP")

#                 # Update max severity
#                 if (( SEVERITY > max_severity )); then
#                     max_severity=$SEVERITY
#                 fi
#             fi
#         done < <(jq -r '.patterns[] | select(.category == "AppFailure" or .category == "AppRestart") | .match' "${ERROR_JSON}")

#         # for pattern in "${!ERROR_AGGREGATE[@]}"; do
#         #     DETAILS=$(jq -Rs . <<< "${ERROR_AGGREGATE[$pattern]}")

#         #     CATEGORY=$(jq -r --arg pattern "$pattern" '.patterns[] | select(.match == $pattern) | .category' "${ERROR_JSON}")
#         #     SEVERITY=$(jq -r --arg pattern "$pattern" '.patterns[] | select(.match == $pattern) | .severity' "${ERROR_JSON}")
#         #     NEXT_STEP=$(jq -r --arg pattern "$pattern" '.patterns[] | select(.match == $pattern) | .next_step' "${ERROR_JSON}")

#         #     NEXT_STEP="${NEXT_STEP//\$\{WORKLOAD_TYPE\}/${WORKLOAD_TYPE}}"
#         #     NEXT_STEP="${NEXT_STEP//\$\{WORKLOAD_NAME\}/\`${WORKLOAD_NAME}\`}"
#         #     NEXT_STEP="${NEXT_STEP//\$\{NAMESPACE\}/\`${NAMESPACE}\`}"

#         #     # Adjust recommendations based on occurrence severity
#         #     OCCURRENCES=${ERROR_STATS["$pattern"]}
#         #     if ((OCCURRENCES >= 10)); then
#         #         NEXT_STEP+=" Multiple failures detected (${OCCURRENCES} occurrences). Immediate debugging required."
#         #         SEVERITY=1
#         #     elif ((OCCURRENCES >= 5)); then
#         #         NEXT_STEP+=" Repeated failures detected (${OCCURRENCES} occurrences). Consider checking readiness and liveness probes."
#         #         SEVERITY=2
#         #     fi

#         #     ISSUES_JSON=$(echo "$ISSUES_JSON" | jq \
#         #         --arg title "Application Restart/Failure Detected in ${POD} (${CONTAINER}) - ${CATEGORY}" \
#         #         --arg details "${DETAILS}" \
#         #         --arg nextStep "${NEXT_STEP}" \
#         #         --arg severity "${SEVERITY}" \
#         #         --arg occurrences "$OCCURRENCES" \
#         #         '.issues += [{"title": $title, "details": $details, "next_steps": $nextStep, "severity": ($severity | tonumber), "occurrences": ($occurrences | tonumber)}]'
#         #     )
#         # done
#     done
# done


# ###############################################################################
# # 3) If we have any matches, build a SINGLE issue
# ###############################################################################
# if [[ ${#aggregator[@]} -gt 0 ]]; then
#     # Build a single JSON object for "details" grouping logs by container name
#     DETAILS_JSON="{}"
#     for container_name in "${!aggregator[@]}"; do
#         if [[ -n "${aggregator[$container_name]}" ]]; then
#             # JSON-escape the multi-line log excerpt
#             escaped_lines="$(jq -Rs . <<< "${aggregator[$container_name]}")"
#             # Add to the details object:  details.container_name = <escaped_lines>
#             DETAILS_JSON=$(echo "$DETAILS_JSON" | jq \
#                 --arg c "$container_name" \
#                 --arg v "$escaped_lines" \
#                 '. + {($c): ($v | fromjson)}'
#             )
#         fi
#     done

#     # Deduplicate next steps
#     #   We'll produce an array of unique nextSteps in JSON
#     #   The simplest approach is to let jq handle uniqueness with a combination
#     #   of inputs|unique.
#     #   We can feed each next step line to jq, build an array, then apply unique.
    
#     # Let's write them to a temporary file or use process substitution:
#     # Then read them back with jq -s. Example:
#     unique_next_steps_json="$(printf '%s\n' "${all_next_steps[@]}" \
#       | jq -Rs --slurp 'split("\n")[:-1] | unique'
#     )"
#     # Explanation:
#     #   - We print all next steps lines, one per line
#     #   - jq -Rs --slurp takes them all at once as a single string,
#     #     then splits on newlines to form an array
#     #   - [:-1] drops the last empty line
#     #   - unique deduplicates them

#     # Now we can build the single final issue with an array of unique next steps
#     TITLE="Application Restart/Failure Errors detected in deployment \`${WORKLOAD_NAME}\` (namespace \`${NAMESPACE}\`) - ${CATEGORY})"
    
#     ISSUES_JSON=$(echo "$ISSUES_JSON" | jq \
#         --arg title "$TITLE" \
#         --argjson details "$DETAILS_JSON" \
#         --argjson steps "$unique_next_steps_json" \
#         --arg severity "$max_severity" \
#         '.issues += [
#            {
#              "title": $title,
#              "details": $details,
#              "next_steps": $steps,
#              "severity": ($severity | tonumber)
#            }
#         ]'
#     )
# fi

# ###############################################################################
# # 4) Write final JSON output
# ###############################################################################
# echo "${ISSUES_JSON}" > "$ISSUES_OUTPUT"
# echo "Finished. Wrote single aggregated issue to $ISSUES_OUTPUT"


# # Generate summary
# if [[ ${#ERROR_COUNTS[@]} -gt 0 ]]; then
#     UNIQUE_CATEGORIES=$(printf "%s\n" "${ERROR_COUNTS[@]}" | sort -u | paste -sd ", ")
#     SUMMARY="Detected application restarts and failures affecting ${UNIQUE_CATEGORIES}."
# else
#     SUMMARY="No application restarts or failures detected."
# fi

# ISSUES_JSON=$(echo "$ISSUES_JSON" | jq --arg summary "$SUMMARY" '.summary = $summary')

# echo "${ISSUES_JSON}" > $ISSUES_OUTPUT
