#!/bin/bash

# Function to extract timestamp from log line, fallback to current time
extract_log_timestamp() {
    local log_line="$1"
    local fallback_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    if [[ -z "$log_line" ]]; then
        echo "$fallback_timestamp"
        return
    fi
    
    # Try to extract common timestamp patterns
    # ISO 8601 format: 2024-01-15T10:30:45.123Z
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z?) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Standard log format: 2024-01-15 10:30:45
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        # Convert to ISO format
        local extracted_time="${BASH_REMATCH[1]}"
        local iso_time=$(date -d "$extracted_time" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # DD-MM-YYYY HH:MM:SS format
    if [[ "$log_line" =~ ([0-9]{2}-[0-9]{2}-[0-9]{4}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        local extracted_time="${BASH_REMATCH[1]}"
        # Convert DD-MM-YYYY to YYYY-MM-DD for date parsing
        local day=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f1)
        local month=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f2)
        local year=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f3)
        local time_part=$(echo "$extracted_time" | cut -d' ' -f2)
        local iso_time=$(date -d "$year-$month-$day $time_part" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # Fallback to current timestamp
    echo "$fallback_timestamp"
}

REPORT_FILE="istio_installation_report.txt"
ISSUES_FILE="istio_installation_issues.json"
LOG_TAIL_COUNT=50  # ⬅️ Set the number of log lines to tail here

# Prepare files
echo ""  >"$REPORT_FILE"
echo "[]" >"$ISSUES_FILE"

# ---------- validation ----------
check_command_exists() {
    if ! command -v "$1" &>/dev/null; then        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

        # Extract timestamp from log context


        log_timestamp=$(extract_log_timestamp "$0")


        echo "Error: $1 could not be found (detected at $log_timestamp)"
        exit 1
    fi
}

check_cluster_connection() {
    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" config get-contexts "${CONTEXT}" --no-headers &>/dev/null; then
        echo "=== Available Contexts ==="
        "${KUBERNETES_DISTRIBUTION_BINARY}" config get-contexts        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

        # Extract timestamp from log context


        log_timestamp=$(extract_log_timestamp "$0")


        echo "Error: Unable to get cluster contexts (detected at $log_timestamp)"
        exit 1
    fi
    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" cluster-info --context="${CONTEXT}" &>/dev/null; then        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

        # Extract timestamp from log context


        log_timestamp=$(extract_log_timestamp "$0")


        echo "Error: Unable to connect to the cluster (detected at $log_timestamp)"
        exit 1
    fi
    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" get --raw="/api" --context="${CONTEXT}" &>/dev/null; then        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

        # Extract timestamp from log context


        log_timestamp=$(extract_log_timestamp "$0")


        echo "Error: Unable to reach Kubernetes API server (detected at $log_timestamp)"
        exit 1
    fi
}

check_jq_error() {
    [[ $? -ne 0 ]] && { # Extract timestamp from log context
 log_timestamp=$(extract_log_timestamp "$0")
 echo "Error: Failed to parse JSON (detected at $log_timestamp)"; exit 1; }
}

check_command_exists "${KUBERNETES_DISTRIBUTION_BINARY}"
check_command_exists jq
check_cluster_connection

# ---------- variables ----------
ISTIO_COMPONENTS=("istiod" "istio-ingressgateway" "istio-egressgateway")
ISTIO_NAMESPACES=$("${KUBERNETES_DISTRIBUTION_BINARY}" get namespaces --context="${CONTEXT}" \
                   --no-headers -o custom-columns=":metadata.name" | grep istio)

declare -a ISSUES=()

echo "🔍 Checking Istio Control Plane Components..."
echo "-----------------------------------------------------------------------------------------------------------"
printf "%-25s %-15s %-20s %-15s %-15s %-15s\n" \
       "Component" "Namespace" "Status" "Pods" "Restarts" "Warnings/Errors"
echo "-----------------------------------------------------------------------------------------------------------"

for COMPONENT in "${ISTIO_COMPONENTS[@]}"; do
    COMPONENT_FOUND=false

    for NS in $ISTIO_NAMESPACES; do
        PODS=$("${KUBERNETES_DISTRIBUTION_BINARY}" get pods -n "$NS" \
               -l app="$COMPONENT" --no-headers -o custom-columns=":metadata.name" \
               --context="${CONTEXT}")

        [[ -z "$PODS" ]] && continue
        COMPONENT_FOUND=true

        TOTAL_PODS=0
        RUNNING_PODS=0
        TOTAL_RESTARTS=0
        TOTAL_WARNINGS=0

        for POD in $PODS; do
            TOTAL_PODS=$((TOTAL_PODS + 1))

            POD_STATUS=$("${KUBERNETES_DISTRIBUTION_BINARY}" get pod "$POD" -n "$NS" \
                         -o jsonpath="{.status.phase}" --context="${CONTEXT}")
            [[ "$POD_STATUS" == "Running" ]] && RUNNING_PODS=$((RUNNING_PODS + 1))

            RESTARTS=$("${KUBERNETES_DISTRIBUTION_BINARY}" get pod "$POD" -n "$NS" \
                       -o jsonpath="{.status.containerStatuses[*].restartCount}" \
                       --context="${CONTEXT}")
            RESTARTS_SUM=0
            for COUNT in $RESTARTS; do RESTARTS_SUM=$((RESTARTS_SUM + COUNT)); done
            TOTAL_RESTARTS=$((TOTAL_RESTARTS + RESTARTS_SUM))

            WARNINGS=$("${KUBERNETES_DISTRIBUTION_BINARY}" get events -n "$NS" \
                       --field-selector involvedObject.name="$POD",type!=Normal \
                       --no-headers --context="${CONTEXT}" 2>/dev/null | wc -l)
            TOTAL_WARNINGS=$((TOTAL_WARNINGS + WARNINGS))

            if (( WARNINGS > 0 )); then
                EVENT_DETAILS=$("${KUBERNETES_DISTRIBUTION_BINARY}" get events -n "$NS" \
                                --field-selector involvedObject.name="$POD",type!=Normal \
                                --sort-by=.metadata.creationTimestamp --context="${CONTEXT}")

                CONTAINERS=$("${KUBERNETES_DISTRIBUTION_BINARY}" get pod "$POD" -n "$NS" \
                             -o jsonpath="{.spec.containers[*].name}" --context="${CONTEXT}")

                {
                    echo ""
                    echo "🔶 Pod: $POD"
                    echo "🔸 Namespace: $NS"
                    echo "🔸 Events:"
                    echo "------------------------------------------"
                    echo "$EVENT_DETAILS"
                    echo "------------------------------------------"
                    for CONTAINER in $CONTAINERS; do
                        echo ""
                        echo "🔸 Logs for container: $CONTAINER (last $LOG_TAIL_COUNT lines)"
                        echo "------------------------------------------"
                        "${KUBERNETES_DISTRIBUTION_BINARY}" logs "$POD" -n "$NS" -c "$CONTAINER" \
                            --tail="$LOG_TAIL_COUNT" --context="${CONTEXT}" 2>&1
                        echo "------------------------------------------"
                    done
                } >>"$REPORT_FILE"

                # ---- issue: pod warnings/events ----
                ISSUES+=("$(jq -n \
                    --arg severity "3" \
                    --arg expected "No warning/error events for pod $POD in namespace $NS" \
                    --arg actual "$EVENT_DETAILS" \
                    --arg title "Warning events for pod \`$POD\` in namespace \`$NS\`" \
                    --arg reproduce "${KUBERNETES_DISTRIBUTION_BINARY} get events -n $NS --field-selector involvedObject.name=$POD,type!=Normal" \
                    --arg next_steps "Investigate the pod events and container logs" \
                    --arg component "$COMPONENT" \
                    --arg pod "$POD" \
                    --arg ns "$NS" \
                    --arg restarts "$RESTARTS_SUM" \
                    --arg warnings "$WARNINGS" \
                    --arg tail "$LOG_TAIL_COUNT" \
                    '{
                        severity:$severity,expected:$expected,actual:$actual,title:$title,
                        reproduce_hint:$reproduce,next_steps:$next_steps,
                        details:{
                            component:$component,
                            pod:$pod,
                            namespace:$ns,
                            restart_count:($restarts|tonumber),
                            warning_event_count:($warnings|tonumber),
                            log_tail_lines:($tail|tonumber)
                        }
                    }')"
                )
            fi
        done

        STATUS="RUNNING"
        if (( TOTAL_PODS != RUNNING_PODS )); then
            STATUS="PARTIALLY RUNNING"
            # ---- issue: not all pods running ----
            ISSUES+=("$(jq -n \
                --arg severity "1" \
                --arg expected "All $COMPONENT pods should be running" \
                --arg actual "$RUNNING_PODS of $TOTAL_PODS pods running for component $COMPONENT in namespace $NS" \
                --arg title "Component $COMPONENT not fully running in namespace \`$NS\`" \
                --arg reproduce "${KUBERNETES_DISTRIBUTION_BINARY} get pods -n $NS -l app=$COMPONENT --context=$CONTEXT" \
                --arg next_steps "Inspect pod status and logs to identify startup issues" \
                --arg component "$COMPONENT" \
                --arg ns "$NS" \
                --arg total "$TOTAL_PODS" \
                --arg running "$RUNNING_PODS" \
                --arg restarts "$TOTAL_RESTARTS" \
                --arg warn "$TOTAL_WARNINGS" \
                '{
                    severity:$severity,expected:$expected,actual:$actual,title:$title,
                    reproduce_hint:$reproduce,next_steps:$next_steps,
                    details:{
                        component:$component,
                        namespace:$ns,
                        total_pods:($total|tonumber),
                        running_pods:($running|tonumber),
                        total_restarts:($restarts|tonumber),
                        total_warnings:($warn|tonumber)
                    }
                }')"
            )
        fi

        printf "%-25s %-15s %-20s %-15s %-15s %-15s\n" \
               "$COMPONENT" "$NS" "$STATUS" "$RUNNING_PODS/$TOTAL_PODS" \
               "$TOTAL_RESTARTS" "$TOTAL_WARNINGS"
    done

    # ---------- component missing ----------
    if [[ "$COMPONENT_FOUND" = false ]]; then
        printf "%-25s %-15s %-20s %-15s %-15s %-15s\n" \
               "$COMPONENT" "N/A" "NOT INSTALLED" "0/0" "0" "N/A"

        ISSUES+=("$(jq -n \
            --arg severity "2" \
            --arg expected "Component $COMPONENT should be installed" \
            --arg actual "Component $COMPONENT not found in any namespace" \
            --arg title "Component $COMPONENT missing in cluster \`${CONTEXT}\`" \
            --arg reproduce "${KUBERNETES_DISTRIBUTION_BINARY} get pods --all-namespaces -l app=$COMPONENT" \
            --arg next_steps "Install or verify Istio component installation" \
            --arg component "$COMPONENT" \
            --arg cluster "$CONTEXT" \
            '{
                severity:$severity,expected:$expected,actual:$actual,title:$title,
                reproduce_hint:$reproduce,next_steps:$next_steps,
                details:{component:$component,cluster_context:$cluster}
            }')"
        )
    fi
done

echo "-----------------------------------------------------------------------------------------------------------"

# ---------- output ----------
if (( ${#ISSUES[@]} > 0 )); then
    printf '%s\n' "${ISSUES[@]}" | jq -s . >"$ISSUES_FILE"
else
    echo "✅ All Istio control plane components are healthy."
fi
