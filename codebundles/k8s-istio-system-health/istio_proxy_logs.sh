#!/bin/bash

#set -euo pipefail

# ---------------------------------------------------------------------------
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

ERROR_JSON="proxy_error_patterns.json"
ISSUES_FILE="istio_proxy_issues.json"
REPORT_FILE="istio_proxy_report.json"
LOG_DURATION="1h"  # Fetch logs from the last 1 hour

echo ""  >"$REPORT_FILE"
echo "[]" >"$ISSUES_FILE"
declare -a ISSUES=()

# ---------------------------------------------------------------------------
# helpers
check_command_exists() { command -v "$1" &>/dev/null || { # Extract timestamp from log context
 log_timestamp=$(extract_log_timestamp "$0")
 echo "Error: $1 not found (detected at $log_timestamp)"; exit 1; }; }

check_cluster_connection() {
  "${KUBERNETES_DISTRIBUTION_BINARY}" config get-contexts "${CONTEXT}" --no-headers &>/dev/null \
    || { # Extract timestamp from log context
 log_timestamp=$(extract_log_timestamp "$0")
 echo "Error: unable to get contexts (detected at $log_timestamp)"; exit 1; }
  "${KUBERNETES_DISTRIBUTION_BINARY}" cluster-info --context="${CONTEXT}" &>/dev/null \
    || { # Extract timestamp from log context
 log_timestamp=$(extract_log_timestamp "$0")
 echo "Error: unable to connect to cluster (detected at $log_timestamp)"; exit 1; }
  "${KUBERNETES_DISTRIBUTION_BINARY}" get --raw="/api" --context="${CONTEXT}" &>/dev/null \
    || { # Extract timestamp from log context
 log_timestamp=$(extract_log_timestamp "$0")
 echo "Error: unable to reach API server (detected at $log_timestamp)"; exit 1; }
}

check_command_exists "${KUBERNETES_DISTRIBUTION_BINARY}"
check_command_exists jq
check_cluster_connection

[[ -f "$ERROR_JSON" ]] || { echo "❌  JSON file '$ERROR_JSON' not found"; exit 1; }

# ---------------------------------------------------------------------------
# namespace selection
NAMESPACES_JSON=$("${KUBERNETES_DISTRIBUTION_BINARY}" get namespaces --context="${CONTEXT}" -o json) \
  || { # Extract timestamp from log context
 log_timestamp=$(extract_log_timestamp "$0")
 echo "Error: failed to get namespaces (detected at $log_timestamp)"; exit 1; }

EXCLUDED_NS_ARRAY=$(echo "${EXCLUDED_NAMESPACES}" | jq -R 'split(",")')
FILTERED_NAMESPACES=$(echo "$NAMESPACES_JSON" | jq -r --argjson excluded "${EXCLUDED_NS_ARRAY}" \
    '.items[].metadata.name | select(. as $ns | ($excluded | index($ns) | not))')

[[ -z "$FILTERED_NAMESPACES" ]] && { # Extract timestamp from log context
 log_timestamp=$(extract_log_timestamp "$0")
 echo "Error: no namespaces found (excluding: ${EXCLUDED_NAMESPACES}) (detected at $log_timestamp)"; exit 1; }

# ---------------------------------------------------------------------------
echo "🔍 Checking istio-proxy logs across namespaces..."
echo "-----------------------------------------------------------"

for NS in $FILTERED_NAMESPACES; do
  PODS=$("${KUBERNETES_DISTRIBUTION_BINARY}" get pods -n "$NS" --context="${CONTEXT}" \
         --no-headers -o custom-columns=":metadata.name")

  for POD in $PODS; do
    CONTAINERS=$("${KUBERNETES_DISTRIBUTION_BINARY}" get pod "$POD" -n "$NS" \
                 --context="${CONTEXT}" -o jsonpath='{.spec.containers[*].name}')

    [[ "$CONTAINERS" != *"istio-proxy"* ]] && continue

    echo "📜  $POD ($NS)"
    LOGS=$("${KUBERNETES_DISTRIBUTION_BINARY}" logs "$POD" -c istio-proxy \
           -n "$NS" --context="${CONTEXT}" --since="$LOG_DURATION" 2>/dev/null)

    # ---------- warnings ----------
    while IFS= read -r WARNING; do
      if grep -Fq "$WARNING" <<<"$LOGS"; then
        echo "  ⚠️  Warning: '$WARNING'"
        ISSUES+=("$(jq -n \
          --arg severity "3" \
          --arg expected "No warnings in istio-proxy logs for pod $POD in namespace $NS" \
          --arg actual "Warning \"$WARNING\" for pod $POD in namespace $NS" \
          --arg title "istio-proxy warning in pod \`$POD\` (ns: \`$NS\`)" \
          --arg reproduce "${KUBERNETES_DISTRIBUTION_BINARY} logs $POD -c istio-proxy -n $NS --context=${CONTEXT} --since=$LOG_DURATION | grep \"$WARNING\"" \
          --arg next_steps "Review mesh config and application behavior producing the warning" \
          --arg pod "$POD" --arg ns "$NS" --arg log "$WARNING" --arg win "$LOG_DURATION" \
          '{severity:$severity,expected:$expected,actual:$actual,title:$title,
            reproduce_hint:$reproduce,next_steps:$next_steps,
            details:{container:"istio-proxy",pod:$pod,namespace:$ns,log_entry:$log,log_window:$win}}')"
        )
      fi
    done < <(jq -r '.warnings[]' "$ERROR_JSON")

    # ---------- errors ----------
    while IFS= read -r ERR; do
      if grep -Fq "$ERR" <<<"$LOGS"; then
        echo "  ❌  Error: '$ERR'"
        ISSUES+=("$(jq -n \
          --arg severity "2" \
          --arg expected "No errors in istio-proxy logs for pod $POD in namespace $NS" \
          --arg actual "Error \"$ERR\" for pod $POD in namespace $NS" \
          --arg title "istio-proxy error in pod \`$POD\` (ns: \`$NS\`)" \
          --arg reproduce "${KUBERNETES_DISTRIBUTION_BINARY} logs $POD -c istio-proxy -n $NS --context=${CONTEXT} --since=$LOG_DURATION | grep \"$ERR\"" \
          --arg next_steps "Investigate misconfiguration, service reachability, or mTLS issues" \
          --arg pod "$POD" --arg ns "$NS" --arg log "$ERR" --arg win "$LOG_DURATION" \
          '{severity:$severity,expected:$expected,actual:$actual,title:$title,
            reproduce_hint:$reproduce,next_steps:$next_steps,
            details:{container:"istio-proxy",pod:$pod,namespace:$ns,log_entry:$log,log_window:$win}}')"
        )
      fi
    done < <(jq -r '.errors[]' "$ERROR_JSON")
  done
done

echo "-----------------------------------------------------------"

# ---------------------------------------------------------------------------
if (( ${#ISSUES[@]} == 0 )); then
  echo "✅  No warnings or errors detected in istio-proxy logs."
else
  echo "⚠️   Issues detected – writing to $ISSUES_FILE"
  printf '%s\n' "${ISSUES[@]}" | jq -s . >"$ISSUES_FILE"
fi

# minimal report
jq -n --arg time "$(date -Iseconds)" --arg status "completed" \
  '{check:"istio-proxy-logs",status:$status,time:$time}' >"$REPORT_FILE"
