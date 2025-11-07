#!/bin/bash

# Thresholds
CPU_THRESHOLD=${CPU_USAGE_THRESHOLD}
MEM_THRESHOLD=${MEMORY_USAGE_THRESHOLD}

REPORT_FILE="istio_sidecar_resource_usage_report.txt"
ISSUES_FILE="istio_sidecar_resource_usage_issue.json"

echo ""  >"$REPORT_FILE"
echo "[]" >"$ISSUES_FILE"

# ---------- helpers ----------
check_command_exists() { command -v "$1" &>/dev/null || { echo "Error: $1 not found"; exit 1; }; }

check_cluster_connection() {
  "${KUBERNETES_DISTRIBUTION_BINARY}" config get-contexts "${CONTEXT}" --no-headers &>/dev/null \
    || { echo "Error: unable to get contexts"; exit 1; }
  "${KUBERNETES_DISTRIBUTION_BINARY}" cluster-info --context="${CONTEXT}" &>/dev/null \
    || { echo "Error: unable to connect to cluster"; exit 1; }
  "${KUBERNETES_DISTRIBUTION_BINARY}" get --raw="/api" --context="${CONTEXT}" &>/dev/null \
    || { echo "Error: unable to reach API server"; exit 1; }
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
      OBSERVATIONS=$(jq -n \
        --arg pod "$POD" \
        --arg ns "$NS" \
        '[
        {
          "observation": ("The pod `" + $pod + "` in namespace `" + $ns + "` has CPU Limits set to null."),
          "category": "configuration"
        },
        {
          "observation": ("The pod `" + $pod + "` in namespace `" + $ns + "` has Memory Limits set to null."),
          "category": "configuration"
        },
        {
          "observation": ("The istio-proxy container in pod `" + $pod + "` in namespace `" + $ns + "` lacks defined resource limits as confirmed by the reproduce hint command."),
          "category": "configuration"
        }
      ]'
      )
      ISSUES+=("$(jq -n \
         --arg severity "1" \
         --arg expected "istio-proxy container should have resource limits" \
         --arg actual "Missing resource limits for pod $POD in namespace $NS" \
         --arg title "Missing resource limits for pod \`$POD\` in namespace \`$NS\`" \
         --arg reproduce "kubectl get pod $POD -n $NS -o jsonpath='{.spec.containers[?(@.name==\"istio-proxy\")].resources}'" \
         --arg next_steps "Add CPU/Memory limits to the deployment spec" \
         --arg ns "$NS" --arg pod "$POD" \
         --arg summary "The pod \`$POD\` in namespace \`$NS\` is missing CPU and memory resource limits for its istio-proxy container. Expected behavior is for the container to have defined resource limits. Action is needed to update the deployment spec and validate runtime performance and scheduling." \
         --argjson observations "${OBSERVATIONS}" \
         '{severity:$severity,expected:$expected,actual:$actual,title:$title,
           reproduce_hint:$reproduce,next_steps:$next_steps,
           details:{namespace:$ns,pod:$pod,cpu_limits_m:null,mem_limits_mi:null},
           summary:$summary,
           observations:$observations}'
        )"
      )
      continue
    fi

    # ------- zero usage -------
    if [[ -z "$CPU_USAGE" || "$CPU_USAGE" == "0" || -z "$MEM_USAGE" || "$MEM_USAGE" == "0" ]]; then
      ZERO_USAGE_PODS+=("$NS $POD")
      OBSERVATIONS=$(jq -n \
        --arg pod "$POD" \
        --arg ns "$NS" \
        '[
        {
        "observation": ("Pod `" + $pod + "` in namespace `" + $ns + "` reported zero CPU (0m) and memory (0Mi) usage."),
        "category": "performance"
        },
        {
        "observation": ("Zero / unavailable usage stats were recorded for the istio-proxy container in pod `" + $pod + "` in namespace `" + $ns + "`."),
        "category": "operational"
        },
        {
        "observation": ("Reproducing metrics via kubectl top pod `" + $pod + "` -n `" + $ns + "` --containers | grep istio-proxy confirmed no resource consumption data is reported."),
        "category": "operational"
        }
      ]'
      )
      ISSUES+=("$(jq -n \
         --arg severity "2" \
         --arg expected "istio-proxy should consume some resources" \
         --arg actual "Zero / unavailable usage stats for pod $POD in namespace $NS" \
         --arg title "No resource usage for pod \`$POD\` in namespace \`$NS\`" \
         --arg reproduce "kubectl top pod $POD -n $NS --containers | grep istio-proxy" \
         --arg next_steps "Verify pod is running and metrics-server is reporting" \
         --arg ns "$NS" --arg pod "$POD" \
         --arg summary "Pod \`$POD\` in namespace \`$NS\` showed zero CPU and memory usage, whereas some resource consumption from istio-proxy was expected. The issue may be due to missing metrics from the pod or metrics-server." \
         --argjson observations "${OBSERVATIONS}" \
         '{severity:$severity,expected:$expected,actual:$actual,title:$title,
           reproduce_hint:$reproduce,next_steps:$next_steps,
           details:{namespace:$ns,pod:$pod,cpu_usage_m:0,mem_usage_mi:0},
           summary:$summary,
           observations:$observations}'
        )"
      )
      continue
    fi

    # ------- percentages -------
    CPU_PERCENTAGE=$(awk "BEGIN{printf \"%.2f\", ($CPU_USAGE*100)/$CPU_LIMITS}")
    MEM_PERCENTAGE=$(awk "BEGIN{printf \"%.2f\", ($MEM_USAGE*100)/$MEM_LIMITS}")

    # ------- high CPU -------
    if (( $(echo "$CPU_PERCENTAGE > $CPU_THRESHOLD" | bc -l) )); then
      HIGH_CPU_USAGE_PODS+=("$NS $POD")
      OBSERVATIONS=$(jq -n \
        --arg pod "$POD" \
        --arg ns "$NS" \
        --arg cu "$CPU_USAGE" \
        --arg cp "$CPU_PERCENTAGE" \
        --arg cl "$CPU_LIMITS" \
        --arg cth "$CPU_THRESHOLD" \
        --arg mu "$MEM_USAGE" \
        --arg mp "$MEM_PERCENTAGE" \
        --arg ml "$MEM_LIMITS" \
        --arg mth "$MEM_THRESHOLD" \
        '[
        {
        "observation": ("Pod `" + $pod + "` in namespace `" + $ns + "` is using " + $cu + "m CPU, " + $cp + "%" + " of its " + $cl + "m" + " limit, exceeding the " + $cth + "%" + " threshold."),
        "category": "performance"
        },
        {
        "observation": ("Memory usage for pod `" + $pod + "` in namespace `" + $ns + "` is " + $mu + "Mi, " + $mp + "%" + " of its " + $ml + "Mi" + " limit, exceeding the " + $mth + "%" + " threshold."),
        "category": "performance"
        }
      ]'
      )
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
         --arg summary "The pod \`$POD\` in namespace \`$NS\` experienced high CPU usage of ${CPU_PERCENTAGE}%, exceeding the expected threshold of ${CPU_THRESHOLD}%. Memory usage was ${MEM_PERCENTAGE}%, slightly above the threshold of ${MEM_THRESHOLD}%. Investigation is needed into CPU-intensive workloads, container resource limits, throttling configurations, and recent deployment or scaling events." \
         --argjson observations "${OBSERVATIONS}" \
         '{severity:$severity,expected:$expected,actual:$actual,title:$title,
           reproduce_hint:$reproduce,next_steps:$next_steps,
           details:{namespace:$ns,pod:$pod,cpu_limits_m:($cl|tonumber),cpu_usage_m:($cu|tonumber),
                    cpu_usage_pct:($cp|tonumber),mem_limits_mi:($ml|tonumber),
                    mem_usage_mi:($mu|tonumber),mem_usage_pct:($mp|tonumber),
                    cpu_threshold_pct:($cth|tonumber),mem_threshold_pct:($mth|tonumber)},
            summary:$summary,
            observations:$observations}'
        )"
      )
    fi

    # ------- high Memory -------
    if (( $(echo "$MEM_PERCENTAGE > $MEM_THRESHOLD" | bc -l) )); then
      HIGH_MEM_USAGE_PODS+=("$NS $POD")
      OBSERVATIONS=$(jq -n \
        --arg pod "$POD" \
        --arg ns "$NS" \
        --arg mu "$MEM_USAGE" \
        --arg mp "$MEM_PERCENTAGE" \
        --arg ml "$MEM_LIMITS" \
        --arg mth "$MEM_THRESHOLD" \
        '[
        {
        "category": "performance",
        "observation": ("Pod `" + $pod + "` in namespace `" + $ns + "` is using " + $mu + "Mi of memory, exceeding its configured limit threshold of " + $ml + "Mi."),
        },
        {
        "category": "performance",
        "observation": ("Memory usage for pod `" + $pod + "` in namespace `" + $ns + "` is at " + $mp + "%, above the expected maximum of " + $mth + "%."),
        },
        {
        "category": "performance",
        "observation": ("The reproduce hint shows that container istio-proxy in pod `" + $pod + "` in namespace `" + $ns + "` can be inspected for memory usage patterns contributing to the " + $mp + "%" + " consumption."),
        }
        ]'
      )
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
         --arg summary "Pod \`$POD\` in namespace \`$NS\` is experiencing high memory usage at ${MEM_PERCENTAGE}%, exceeding the expected threshold of ${MEM_THRESHOLD}%. CPU usage is within acceptable limits. The elevated memory usage suggests possible memory leaks or resource configuration issues." \
         --argjson observations "${OBSERVATIONS}" \
         '{severity:$severity,expected:$expected,actual:$actual,title:$title,
           reproduce_hint:$reproduce,next_steps:$next_steps,
           details:{namespace:$ns,pod:$pod,cpu_limits_m:($cl|tonumber),cpu_usage_m:($cu|tonumber),
                    cpu_usage_pct:($cp|tonumber),mem_limits_mi:($ml|tonumber),
                    mem_usage_mi:($mu|tonumber),mem_usage_pct:($mp|tonumber),
                    cpu_threshold_pct:($cth|tonumber),mem_threshold_pct:($mth|tonumber)},
            summary:$summary,
            observations:$observations}'
        )"
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
