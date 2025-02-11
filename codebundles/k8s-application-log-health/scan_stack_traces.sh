#!/usr/bin/env bash

################################################################################
# SCAN_STACK_TRACES.SH
#
# This script scans logs for stack traces across multiple languages,
# capturing the preceding lines for added context. It then outputs
# a JSON summary of detected traces, including file/line reference
# (if available), severity, and recommended next steps as a true array.
#
# Common Stack-Trace Patterns:
#  - Java, Python, Node.js, .NET, Go, Ruby, C/C++ (segfault)
# Adjust patterns below in AWK or grep as needed.
################################################################################

# Arguments / Defaults
NAMESPACE=${1:-$NAMESPACE}
WORKLOAD_TYPE=${2:-$WORKLOAD_TYPE}
WORKLOAD_NAME=${3:-$WORKLOAD_NAME}
LOG_LINES=${4:-1000}
CONTEXT=${5:-$CONTEXT}

ERROR_JSON="error_patterns.json"

# Number of lines to capture *before* the start of a stack trace
PRECEDING_LINES=${PRECEDING_LINES:-25}

SHARED_TEMP_DIR="${SHARED_TEMP_DIR:-/tmp}"
ISSUES_OUTPUT="${SHARED_TEMP_DIR}/scan_stacktrace_issues.json"

# Start with an empty JSON structure
ISSUES_JSON='{"issues": []}'

echo "Scanning logs for stack traces in '${WORKLOAD_TYPE}/${WORKLOAD_NAME}' in namespace '${NAMESPACE}' (context: '${CONTEXT}')..."

# 1) Get list of pods from local JSON (adjust path as needed)
PODS=($(jq -r '.[].metadata.name' "${SHARED_TEMP_DIR}/application_logs_pods.json"))

# 2) Iterate over each pod
for POD in "${PODS[@]}"; do
    echo "Processing Pod ${POD}"

    # 2a) Extract container names from JSON
    CONTAINERS=$(jq -r --arg POD "$POD" '
      .[]
      | select(.metadata.name == $POD)
      | .spec.containers[].name
    ' "${SHARED_TEMP_DIR}/application_logs_pods.json")

    # 2b) For each container, read the local logs
    for CONTAINER in ${CONTAINERS}; do
        echo "  Processing Container ${CONTAINER}"

        LOG_FILE="${SHARED_TEMP_DIR}/${WORKLOAD_TYPE}_${WORKLOAD_NAME}_logs/${POD}_${CONTAINER}_logs.txt"
        TRACE_FILE="${SHARED_TEMP_DIR}/${POD}_${CONTAINER}_trace.txt"
        : > "${TRACE_FILE}"  # Clear/overwrite existing contents

        if [[ ! -f "$LOG_FILE" ]]; then
            echo "  Warning: No log file found at $LOG_FILE" >&2
            continue
        fi

        ############################################################
        # AWK PASS #1:  Capture preceding lines + stack traces
        #
        # - We keep a ring buffer of the last N (PRECEDING_LINES) lines.
        # - If we detect a "start" pattern (Exception, Traceback, panic, etc.),
        #   we print that buffer first, then print lines until we
        #   hit a blank line or a non-stack-trace line.
        ############################################################
        awk -v PRECEDING_LINES="${PRECEDING_LINES}" '
          BEGIN {
            # circular buffer
            for (i=0; i<PRECEDING_LINES; i++) {
              buffer[i] = ""
            }
            bufIndex = 0
            capturing = 0
          }

          function print_buffer() {
            for (i=0; i<PRECEDING_LINES; i++) {
              idx = (bufIndex + i) % PRECEDING_LINES
              if (buffer[idx] != "") {
                print buffer[idx]
              }
            }
          }

          {
            # store line in ring buffer
            buffer[bufIndex] = $0
            bufIndex = (bufIndex + 1) % PRECEDING_LINES
          }

          # Start patterns: Exception, Traceback, panic, Caused by, segfault, core dumped
          /Exception|Traceback|panic:|^Caused by:|segmentation fault|core dumped/ {
            print_buffer()
            print $0
            capturing = 1
            next
          }

          # If capturing, check if line is part of the trace
          capturing {
            if (match($0, /^\s+at\s+/) ||                      # Java, Node, .NET
                match($0, /^\s+File\s+".*",\s+line\s+\d+/) ||  # Python
                match($0, /^\s+[a-zA-Z0-9_]+(\.[a-zA-Z0-9_]+)*\(/) ||
                match($0, /^\s+at\s+\S+:\d+:\d+/) ||
                length($0) == 0) {

              # blank line => stop capturing
              if (length($0) == 0) {
                capturing = 0
              } else {
                print $0
              }
            } else {
              capturing = 0
            }
          }
        ' "${LOG_FILE}" > "${TRACE_FILE}" 2>/dev/null

        # 3) If TRACE_FILE is non-empty => we found stack traces
        if [[ -s "${TRACE_FILE}" ]]; then
            # Identify first "source file" reference
            SOURCE_FILE=$(
              grep -m1 -oE \
                'File "[^"]+", line [0-9]+|[^( ]+\.(java|py|go|rb|php|js|ts|cs|vb|fs):[0-9]+|at [^:()]+(\.[^:()]+)*\([^:]+:[0-9]+\)' \
                "${TRACE_FILE}"
            )

            # Determine stack-trace category from known patterns
            MATCHED_PATTERN=""
            SEVERITY=""
            
            #######################################################
            # IMPORTANT: Use `-c` (compact) instead of `-r` so we
            # get a valid JSON array from .next_steps if it exists.
            #######################################################
            NEXT_STEP_JSON=$(
              jq -c --arg pattern "${MATCHED_PATTERN}" \
                '.patterns[] 
                  | select(.match == $pattern) 
                  | .next_steps' \
                "${ERROR_JSON}" 2>/dev/null
            )

            # If we didn't find a direct match, we try matching all "Exceptions" patterns
            # or fallback to something generic
            if [[ -z "${NEXT_STEP_JSON}" || "${NEXT_STEP_JSON}" == "null" ]]; then
              while read -r pattern; do
                  if grep -qEi "${pattern}" "${TRACE_FILE}"; then
                      MATCHED_PATTERN="${pattern}"
                      CATEGORY=$(jq -r --arg pattern "${pattern}" '.patterns[] | select(.match == $pattern) | .category' "${ERROR_JSON}")
                      SEVERITY=$(jq -r --arg pattern "${pattern}" '.patterns[] | select(.match == $pattern) | .severity' "${ERROR_JSON}")

                      # Now get next_steps as a JSON array, if possible
                      NEXT_STEP_JSON=$(jq -c --arg pattern "${pattern}" \
                        '.patterns[] 
                          | select(.match == $pattern) 
                          | .next_steps' \
                        "${ERROR_JSON}")
                      break
                  fi
              done < <(jq -r '.patterns[] | select(.category == "Exceptions") | .match' "${ERROR_JSON}")
            else
              # We found a direct match for `MATCHED_PATTERN` above
              # If you also store "category" in the same block, do it similarly
              CATEGORY=$(jq -r --arg pattern "${MATCHED_PATTERN}" '.patterns[] | select(.match == $pattern) | .category' "${ERROR_JSON}")
              SEVERITY=$(jq -r --arg pattern "${MATCHED_PATTERN}" '.patterns[] | select(.match == $pattern) | .severity' "${ERROR_JSON}")
            fi

            # If STILL no array for next_steps, provide a default:
            if [[ -z "${NEXT_STEP_JSON}" || "${NEXT_STEP_JSON}" == "null" ]]; then
                NEXT_STEP_JSON='["Investigate the stack trace. Identify the root cause and debug accordingly."]'
                SEVERITY=${SEVERITY:-3}
                CATEGORY=${CATEGORY:-"Unknown"}
            fi

            # 4) Merge into ISSUES_JSON using --rawfile for large logs
            #    and --argjson for next_steps array
            ISSUES_JSON="$(
              echo "${ISSUES_JSON}" \
              | jq \
                --rawfile trace "${TRACE_FILE}" \
                --arg title      "Stack Trace Detected in ${POD} (${CONTAINER}) - ${CATEGORY}" \
                --arg severity   "${SEVERITY}" \
                --arg sourceFile "${SOURCE_FILE}" \
                --argjson nextSteps "${NEXT_STEP_JSON}" \
                '.issues += [{
                  "title": $title,
                  "details": $trace,
                  "next_steps": $nextSteps,
                  "severity": ($severity | tonumber),
                  "source_file": $sourceFile
                }]'
            )"
        fi
    done
done

# 5) Write final JSON
echo "${ISSUES_JSON}" > "${ISSUES_OUTPUT}"
echo "Results written to ${ISSUES_OUTPUT}"
