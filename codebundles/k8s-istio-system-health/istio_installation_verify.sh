#!/bin/bash

REPORT_FILE="istio_installation_report.txt"
ISSUES_FILE="istio_installation_issues.json"
LOG_TAIL_COUNT=50  # ⬅️ Set the number of log lines to tail here

# Prepare files
echo ""  >"$REPORT_FILE"
echo "[]" >"$ISSUES_FILE"

# ---------- validation ----------
check_command_exists() {
    if ! command -v "$1" &>/dev/null; then
        echo "Error: $1 could not be found"
        exit 1
    fi
}

check_cluster_connection() {
    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" config get-contexts "${CONTEXT}" --no-headers &>/dev/null; then
        echo "=== Available Contexts ==="
        "${KUBERNETES_DISTRIBUTION_BINARY}" config get-contexts
        echo "Error: Unable to get cluster contexts"
        exit 1
    fi
    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" cluster-info --context="${CONTEXT}" &>/dev/null; then
        echo "Error: Unable to connect to the cluster"
        exit 1
    fi
    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" get --raw="/api" --context="${CONTEXT}" &>/dev/null; then
        echo "Error: Unable to reach Kubernetes API server"
        exit 1
    fi
}

check_jq_error() {
    [[ $? -ne 0 ]] && { echo "Error: Failed to parse JSON"; exit 1; }
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

                # Combine REASON and MESSAGE columns from EVENT_DETAILS into a single string per line, separated by ": "
                COMBINED_REASON_MESSAGE=$(echo "$EVENT_DETAILS" | awk 'NR>1 && NR<=4 {print $3 ": " substr($0, index($0,$6))}')

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
                    --arg summary "Pod \`$POD\` in namespace \`$NS\` experienced $WARNINGS warning events: $COMBINED_REASON_MESSAGE. The expected behavior was no warning or error events. Investigation of pod events, container logs, and resource usage is needed to identify potential \`$COMPONENT\` integration or scheduling issues." \
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
                        },
                        summary:$summary,
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
                --arg summary "The \`$COMPONENT\` component in namespace \`$NS\` is not running, with $RUNNING_PODS of $TOTAL_PODS pods active, although all pods were expected to be running. No pod restarts or warnings were observed, indicating a startup or scheduling issue that requires investigation." \
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
                    },
                    summary:$summary,
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
            --arg summary "The \`$COMPONENT\` component is missing in cluster \`${CONTEXT}\`. It was expected to be installed and operational, but it was not found in any namespace. This indicates a potential installation or deployment issue that requires verification of the component and investigation of the cluster's control plane and namespace resources." \
            '{
                severity:$severity,expected:$expected,actual:$actual,title:$title,
                reproduce_hint:$reproduce,next_steps:$next_steps,
                details:{component:$component,cluster_context:$cluster},
                summary:$summary
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
