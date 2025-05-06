#!/bin/bash

# Constants
ERROR_JSON="controlplane_error_patterns.json"
ISSUES_FILE="istio_controlplane_issues.json"
REPORT_FILE="istio_controlplane_report.json"
LOG_DURATION="1h"     # Fetch logs from the last 1 hour
declare -a ISSUES=()

# Prepare files
echo ""  >"$REPORT_FILE"
echo "[]" >"$ISSUES_FILE"

# ---------- helpers ----------
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
        echo "Error: Unable to connect to the cluster."
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

# ---------- pre-flight ----------
check_command_exists "${KUBERNETES_DISTRIBUTION_BINARY}"
check_command_exists jq
check_cluster_connection

# ---------- data ----------
ISTIO_NAMESPACES=$("${KUBERNETES_DISTRIBUTION_BINARY}" get namespaces --context="${CONTEXT}" -o custom-columns=":metadata.name" | grep istio)
ISTIO_COMPONENTS=("istiod" "istio-ingressgateway" "istio-egressgateway")

[[ ! -f "$ERROR_JSON" ]] && { echo "❌  JSON file '$ERROR_JSON' not found"; exit 1; }

WARNINGS=($(jq -r '.warnings[]' "$ERROR_JSON"))
ERRORS=($(jq -r '.errors[]'   "$ERROR_JSON"))

echo "🔍  Checking Istio Control-Plane logs for exact matches"
echo "------------------------------------------------------"

for COMPONENT in "${ISTIO_COMPONENTS[@]}"; do
  for NS in $ISTIO_NAMESPACES; do
    PODS=$("${KUBERNETES_DISTRIBUTION_BINARY}" get pods -n "$NS" --context="${CONTEXT}" \
           -l "app=$COMPONENT" -o custom-columns=":metadata.name" --no-headers)

    for POD in $PODS; do
      echo "📜  $POD ($NS)"
      LOGS=$("${KUBERNETES_DISTRIBUTION_BINARY}" logs "$POD" -n "$NS" --context="${CONTEXT}" \
             --since="$LOG_DURATION" 2>/dev/null)

      # ---------- warnings ----------
      for WARNING in "${WARNINGS[@]}"; do
        if grep -Fq "$WARNING" <<< "$LOGS"; then
          echo "  ⚠️  Warning found: '$WARNING'"
          ISSUES+=("$(jq -n \
             --arg severity "3" \
             --arg expected "No warning logs in control-plane pod $POD in namespace $NS" \
             --arg actual "Warning \"$WARNING\" for control-plane pod $POD in namespace $NS" \
             --arg title "Warning in pod \`$POD\` (\`$COMPONENT\`) in namespace \`$NS\`" \
             --arg reproduce "${KUBERNETES_DISTRIBUTION_BINARY} logs $POD -n $NS --context=${CONTEXT} --since=$LOG_DURATION | grep \"$WARNING\"" \
             --arg next_steps "Investigate the warning log entry for pod \`$POD\` in namespace \`$NS\`" \
             --arg component "$COMPONENT" \
             --arg pod "$POD" \
             --arg ns "$NS" \
             --arg log_text "$WARNING" \
             --arg window "$LOG_DURATION" \
             '{severity:$severity,expected:$expected,actual:$actual,title:$title,reproduce_hint:$reproduce,next_steps:$next_steps,
               details:{component:$component,pod:$pod,namespace:$ns,log_entry:$log_text,log_window:$window}}')"
          )
        fi
      done

      # ---------- errors ----------
      for ERR in "${ERRORS[@]}"; do
        if grep -Fq "$ERR" <<< "$LOGS"; then
          echo "  ❌  Error found: '$ERR'"
          ISSUES+=("$(jq -n \
             --arg severity "2" \
             --arg expected "No critical logs in control-plane pod $POD in namespace $NS" \
             --arg actual "Error \"$ERR\" for control-plane pod $POD in namespace $NS" \
             --arg title "Error in pod \`$POD\` (\`$COMPONENT\`) in namespace \`$NS\`" \
             --arg reproduce "${KUBERNETES_DISTRIBUTION_BINARY} logs $POD -n $NS --context=${CONTEXT} --since=$LOG_DURATION | grep \"$ERR\"" \
             --arg next_steps "Investigate the error log entry for pod \`$POD\` in namespace \`$NS\`" \
             --arg component "$COMPONENT" \
             --arg pod "$POD" \
             --arg ns "$NS" \
             --arg log_text "$ERR" \
             --arg window "$LOG_DURATION" \
             '{severity:$severity,expected:$expected,actual:$actual,title:$title,reproduce_hint:$reproduce,next_steps:$next_steps,
               details:{component:$component,pod:$pod,namespace:$ns,log_entry:$log_text,log_window:$window}}')"
          )
        fi
      done
    done
  done
done

echo "------------------------------------------------------"

if (( ${#ISSUES[@]} == 0 )); then
  echo "✅  No warnings or errors detected in Istio control-plane logs."
else
  echo "⚠️   Issues detected – writing to $ISSUES_FILE"
  printf '%s\n' "${ISSUES[@]}" | jq -s . >"$ISSUES_FILE"
fi

# Minimal status report
jq -n --arg time "$(date -Iseconds)" --arg status "completed" \
  '{check:"control-plane-logs",status:$status,time:$time}' >"$REPORT_FILE"
