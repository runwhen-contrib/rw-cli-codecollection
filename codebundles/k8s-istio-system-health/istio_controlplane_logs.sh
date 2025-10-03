#!/bin/bash

# Constants
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


        echo "Error: Unable to connect to the cluster. (detected at $log_timestamp)"
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

# ---------- pre-flight ----------
check_command_exists "${KUBERNETES_DISTRIBUTION_BINARY}"
check_command_exists jq
check_cluster_connection

# ---------- data ----------
ISTIO_NAMESPACES=$("${KUBERNETES_DISTRIBUTION_BINARY}" get namespaces --context="${CONTEXT}" -o custom-columns=":metadata.name" | grep istio)
ISTIO_COMPONENTS=("istiod" "istio-ingressgateway" "istio-egressgateway")

[[ ! -f "$ERROR_JSON" ]] && { echo "❌  JSON file '$ERROR_JSON' not found"; exit 1; }

mapfile -t WARNINGS < <(jq -r '.warnings[]' "$ERROR_JSON")
mapfile -t ERRORS   < <(jq -r '.errors[]'   "$ERROR_JSON")

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
        echo "Searching for: $WARNING"
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
        echo "Searching for: $ERR"
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
