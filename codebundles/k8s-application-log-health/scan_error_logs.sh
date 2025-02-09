# #!/bin/bash

python3 ${CURDIR}/scan_logs.py


# For brevity, some environment variables are assumed to be set:
#   NAMESPACE, WORKLOAD_TYPE, WORKLOAD_NAME, OUTPUT_DIR
# We have error_patterns.json with .patterns[] containing "match", "category", "severity", "next_steps"

# ERROR_JSON="error_patterns.json"
# ISSUES_OUTPUT="${OUTPUT_DIR}/scan_error_issues.json"

# # We start with an empty JSON structure
# ISSUES_JSON='{"issues": []}'

# # 1) aggregator: container -> multiline string of matched logs
# declare -A aggregator

# # 2) A list/array of next steps from all patterns we matched
# all_next_steps=()

# # 3) Track the maximum severity encountered
# max_severity=0

# echo "Scanning logs for errors in ${WORKLOAD_TYPE}/${WORKLOAD_NAME} in namespace ${NAMESPACE}..."

# ###############################################################################
# # 1) Collect a list of pods from your earlier JSON
# ###############################################################################
# PODS=($(jq -r '.[].metadata.name' "${OUTPUT_DIR}/application_logs_pods.json"))

# ###############################################################################
# # 2) Loop over pods -> containers -> patterns
# ###############################################################################
# for POD in "${PODS[@]}"; do
#     echo "Processing Pod: $POD"

#     # Extract container names from the same JSON
#     CONTAINERS=$(jq -r --arg POD "$POD" '
#       .[] 
#       | select(.metadata.name == $POD)
#       | .spec.containers[].name
#     ' "${OUTPUT_DIR}/application_logs_pods.json")

#     for CONTAINER in ${CONTAINERS}; do
#         echo "  Processing Container: $CONTAINER"

#         LOG_FILE="${OUTPUT_DIR}/${WORKLOAD_TYPE}_${WORKLOAD_NAME}_logs/${POD}_${CONTAINER}_logs.txt"
#         if [[ ! -f "$LOG_FILE" ]]; then
#             echo "  Warning: No log file found at $LOG_FILE" >&2
#             continue
#         fi

#         # For each relevant pattern in your error JSON
#         while read -r pattern; do
#             MATCHED_LINES=$(grep -Pi "${pattern}" "${LOG_FILE}" || true)
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
#         done < <(jq -r '
#           .patterns[]
#           | select(.category == "GenericError" or .category == "AppFailure")
#           | .match
#         ' "${ERROR_JSON}")
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
#     TITLE="Errors detected in deployment \`${WORKLOAD_NAME}\` (namespace \`${NAMESPACE}\`)-${CATEGORY}"
    
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
