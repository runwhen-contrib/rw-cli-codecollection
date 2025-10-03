#!/bin/bash

# Thresholds
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

CPU_THRESHOLD=${CPU_USAGE_THRESHOLD}
MEM_THRESHOLD=${MEMORY_USAGE_THRESHOLD}

REPORT_FILE="istio_sidecar_resource_usage_report.txt"
ISSUES_FILE="istio_sidecar_resource_usage_issue.json"

echo ""  >"$REPORT_FILE"
echo "[]" >"$ISSUES_FILE"

# ---------- helpers ----------
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

# ---------- arrays ----------
ISSUES=()
NO_LIMITS_PODS=()
ZERO_USAGE_PODS=()
HIGH_CPU_USAGE_PODS=()
HIGH_MEM_USAGE_PODS=()

# ---------- report header ----------
{
  printf "%-15s %-40s %-15s %-15s %-15s %-15s %-15s %-15s\n" \
    "Namespace" "Pod" "CPU_Limits(m)" "CPU_Usage(m)" "CPU_Usage(%)" \
    "Mem_Limits(Mi)" "Mem_Usage(Mi)" "Mem_Usage(%)"
  echo "-----------------------------------------------------------------------------------------------------------------------------------------------------"
} >"$REPORT_FILE"

# ---------- data collection ----------
NAMESPACES=$("${KUBERNETES_DISTRIBUTION_BINARY}" get namespaces --context="${CONTEXT}" \
             --no-headers -o custom-columns=":metadata.name")

for NS in $NAMESPACES; do
  PODS=$("${KUBERNETES_DISTRIBUTION_BINARY}" get pods -n "$NS" --context="${CONTEXT}" \
          -o jsonpath="{.items[*].metadata.name}")

  for POD in $PODS; do
    CONTAINER_NAMES=$("${KUBERNETES_DISTRIBUTION_BINARY}" get pod "$POD" -n "$NS" \
                      --context="${CONTEXT}" -o jsonpath="{.spec.containers[*].name}")

    [[ "$CONTAINER_NAMES" != *"istio-proxy"* ]] && continue   # skip pods w/o sidecar

    # ------- limits -------
    CPU_LIMITS_RAW=$("${KUBERNETES_DISTRIBUTION_BINARY}" get pod "$POD" -n "$NS" \
                     --context="${CONTEXT}" -o jsonpath="{.spec.containers[?(@.name=='istio-proxy')].resources.limits.cpu}")
    CPU_LIMITS=$(echo "$CPU_LIMITS_RAW" | sed 's/m//')
    [[ "$CPU_LIMITS_RAW" =~ ^[0-9]+$ ]] && CPU_LIMITS=$((CPU_LIMITS * 1000))

    MEM_LIMITS_RAW=$("${KUBERNETES_DISTRIBUTION_BINARY}" get pod "$POD" -n "$NS" \
                     --context="${CONTEXT}" -o jsonpath="{.spec.containers[?(@.name=='istio-proxy')].resources.limits.memory}")
    if [[ "$MEM_LIMITS_RAW" == *Gi ]]; then
      MEM_LIMITS=$(( $(echo "$MEM_LIMITS_RAW" | sed 's/Gi//') * 1024 ))
    else
      MEM_LIMITS=$(echo "$MEM_LIMITS_RAW" | sed 's/Mi//')
    fi

    # ------- usage -------
    CPU_USAGE=$("${KUBERNETES_DISTRIBUTION_BINARY}" top pod "$POD" -n "$NS" \
                --context="${CONTEXT}" --containers 2>/dev/null \
                | awk '$2=="istio-proxy"{print $3}' | sed 's/m//')
    MEM_USAGE_RAW=$("${KUBERNETES_DISTRIBUTION_BINARY}" top pod "$POD" -n "$NS" \
                    --context="${CONTEXT}" --containers 2>/dev/null \
                    | awk '$2=="istio-proxy"{print $4}')

    if [[ "$MEM_USAGE_RAW" == *Gi ]]; then
      MEM_USAGE=$(( $(echo "$MEM_USAGE_RAW" | sed 's/Gi//') * 1024 ))
    else
      MEM_USAGE=$(echo "$MEM_USAGE_RAW" | sed 's/Mi//' )
    fi

    # ------- missing limits -------
    if [[ -z "$CPU_LIMITS" || -z "$MEM_LIMITS" ]]; then
      NO_LIMITS_PODS+=("$NS $POD")
      ISSUES+=("$(jq -n \
         --arg severity "1" \
         --arg expected "istio-proxy container should have resource limits" \
         --arg actual "Missing resource limits for pod $POD in namespace $NS" \
         --arg title "Missing resource limits for pod \`$POD\` in namespace \`$NS\`" \
         --arg reproduce "kubectl get pod $POD -n $NS -o jsonpath='{.spec.containers[?(@.name==\"istio-proxy\")].resources}'" \
         --arg next_steps "Add CPU/Memory limits to the deployment spec" \
         --arg ns "$NS" --arg pod "$POD" \
         '{severity:$severity,expected:$expected,actual:$actual,title:$title,
           reproduce_hint:$reproduce,next_steps:$next_steps,
           details:{namespace:$ns,pod:$pod,cpu_limits_m:null,mem_limits_mi:null}}')"
      )
      continue
    fi

    # ------- zero usage -------
    if [[ -z "$CPU_USAGE" || "$CPU_USAGE" == "0" || -z "$MEM_USAGE" || "$MEM_USAGE" == "0" ]]; then
      ZERO_USAGE_PODS+=("$NS $POD")
      ISSUES+=("$(jq -n \
         --arg severity "2" \
         --arg expected "istio-proxy should consume some resources" \
         --arg actual "Zero / unavailable usage stats for pod $POD in namespace $NS" \
         --arg title "No resource usage for pod \`$POD\` in namespace \`$NS\`" \
         --arg reproduce "kubectl top pod $POD -n $NS --containers | grep istio-proxy" \
         --arg next_steps "Verify pod is running and metrics-server is reporting" \
         --arg ns "$NS" --arg pod "$POD" \
         '{severity:$severity,expected:$expected,actual:$actual,title:$title,
           reproduce_hint:$reproduce,next_steps:$next_steps,
           details:{namespace:$ns,pod:$pod,cpu_usage_m:0,mem_usage_mi:0}}')"
      )
      continue
    fi

    # ------- percentages -------
    CPU_PERCENTAGE=$(awk "BEGIN{printf \"%.2f\", ($CPU_USAGE*100)/$CPU_LIMITS}")
    MEM_PERCENTAGE=$(awk "BEGIN{printf \"%.2f\", ($MEM_USAGE*100)/$MEM_LIMITS}")

    # ------- high CPU -------
    if (( $(echo "$CPU_PERCENTAGE > $CPU_THRESHOLD" | bc -l) )); then
      HIGH_CPU_USAGE_PODS+=("$NS $POD")
      ISSUES+=("$(jq -n \
         --arg severity "3" \
         --arg expected "CPU usage < ${CPU_THRESHOLD}%" \
         --arg actual "CPU usage ${CPU_PERCENTAGE}% for pod $POD" \
         --arg title "High CPU usage for pod \`$POD\` in namespace \`$NS\`" \
         --arg reproduce "kubectl top pod $POD -n $NS --containers | grep istio-proxy" \
         --arg next_steps "Investigate CPU-intensive workload or throttling" \
         --arg ns "$NS" --arg pod "$POD" \
         --arg cl "$CPU_LIMITS" --arg cu "$CPU_USAGE" --arg cp "$CPU_PERCENTAGE" \
         --arg ml "$MEM_LIMITS" --arg mu "$MEM_USAGE" --arg mp "$MEM_PERCENTAGE" \
         --arg cth "$CPU_THRESHOLD" --arg mth "$MEM_THRESHOLD" \
         '{severity:$severity,expected:$expected,actual:$actual,title:$title,
           reproduce_hint:$reproduce,next_steps:$next_steps,
           details:{namespace:$ns,pod:$pod,cpu_limits_m:($cl|tonumber),cpu_usage_m:($cu|tonumber),
                    cpu_usage_pct:($cp|tonumber),mem_limits_mi:($ml|tonumber),
                    mem_usage_mi:($mu|tonumber),mem_usage_pct:($mp|tonumber),
                    cpu_threshold_pct:($cth|tonumber),mem_threshold_pct:($mth|tonumber)}}')"
      )
    fi

    # ------- high Memory -------
    if (( $(echo "$MEM_PERCENTAGE > $MEM_THRESHOLD" | bc -l) )); then
      HIGH_MEM_USAGE_PODS+=("$NS $POD")
      ISSUES+=("$(jq -n \
         --arg severity "3" \
         --arg expected "Memory usage < ${MEM_THRESHOLD}%" \
         --arg actual "Memory usage ${MEM_PERCENTAGE}% for pod $POD" \
         --arg title "High Memory usage for pod \`$POD\` in namespace \`$NS\`" \
         --arg reproduce "kubectl top pod $POD -n $NS --containers | grep istio-proxy" \
         --arg next_steps "Investigate memory leaks or tuning issues" \
         --arg ns "$NS" --arg pod "$POD" \
         --arg cl "$CPU_LIMITS" --arg cu "$CPU_USAGE" --arg cp "$CPU_PERCENTAGE" \
         --arg ml "$MEM_LIMITS" --arg mu "$MEM_USAGE" --arg mp "$MEM_PERCENTAGE" \
         --arg cth "$CPU_THRESHOLD" --arg mth "$MEM_THRESHOLD" \
         '{severity:$severity,expected:$expected,actual:$actual,title:$title,
           reproduce_hint:$reproduce,next_steps:$next_steps,
           details:{namespace:$ns,pod:$pod,cpu_limits_m:($cl|tonumber),cpu_usage_m:($cu|tonumber),
                    cpu_usage_pct:($cp|tonumber),mem_limits_mi:($ml|tonumber),
                    mem_usage_mi:($mu|tonumber),mem_usage_pct:($mp|tonumber),
                    cpu_threshold_pct:($cth|tonumber),mem_threshold_pct:($mth|tonumber)}}')"
      )
    fi

    # write row
    printf "%-15s %-40s %-15s %-15s %-15s %-15s %-15s %-15s\n" \
      "$NS" "$POD" "$CPU_LIMITS" "$CPU_USAGE" "${CPU_PERCENTAGE}%" \
      "$MEM_LIMITS" "$MEM_USAGE" "${MEM_PERCENTAGE}%" >>"$REPORT_FILE"
  done
done

# ---------- append tables (unchanged) ----------
# ... (tables section left as-is) ...

# ---------- write issues ----------
if (( ${#ISSUES[@]} > 0 )); then
  printf '%s\n' "${ISSUES[@]}" | jq -s . >"$ISSUES_FILE"
else
  echo "No issues detected. Skipping issue file creation."
fi
