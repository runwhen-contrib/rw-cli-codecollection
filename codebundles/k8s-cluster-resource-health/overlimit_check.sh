#!/usr/bin/env bash

context="$CONTEXT"
percentage="${MAX_LIMIT_PERCENTAGE:-80}"

# 1) Fetch Nodes
kubectl get nodes --context "$context" -o json > nodes.json 2>/dev/null

# 2) Convert Node capacities
rm -f node_alloc.txt pod_overlimits.txt pods.tmp
touch node_alloc.txt pod_overlimits.txt

convert_cpu_to_millicores() {
  cpu_str="$1"
  # 500m -> 500, 2 -> 2000, 0.5 -> 500
  if echo "$cpu_str" | grep -Eq '^[0-9]+m$'; then
    echo "${cpu_str%m}"
  elif echo "$cpu_str" | grep -Eq '^[0-9]+$'; then
    echo "$(($cpu_str * 1000))"
  else
    # Fallback for fractional, e.g. "0.5"
    core_value="$(echo "$cpu_str" | sed 's/[^0-9\.]//g')"
    # multiply by 1000
    awk -v val="$core_value" 'BEGIN { printf "%.0f", val * 1000 }'
  fi
}

convert_memory_to_ki() {
  mem_str="$1"
  # 128Mi -> 131072, 2Gi -> 2097152, 512Ki -> 512
  if echo "$mem_str" | grep -Eq '^[0-9]+Ki$'; then
    echo "${mem_str%Ki}"
  elif echo "$mem_str" | grep -Eq '^[0-9]+Mi$'; then
    val="${mem_str%Mi}"
    echo "$((val * 1024))"
  elif echo "$mem_str" | grep -Eq '^[0-9]+Gi$'; then
    val="${mem_str%Gi}"
    echo "$((val * 1024 * 1024))"
  else
    # Fallback for "2G", "256M", etc.
    numeric_val="$(echo "$mem_str" | sed 's/[^0-9\.]//g')"
    if echo "$mem_str" | grep -Eq '[Gg]'; then
      # G -> 1024*1024
      echo "$((numeric_val * 1024 * 1024))"
    elif echo "$mem_str" | grep -Eq '[Mm]'; then
      # M -> 1024
      echo "$((numeric_val * 1024))"
    else
      # Assume Ki
      echo "$numeric_val"
    fi
  fi
}

# 3) Parse node capacities
jq -r '
  .items[] 
  | (
      .metadata.name // ""
    ) + " " + (
      .status.allocatable.cpu // ""
    ) + " " + (
      .status.allocatable.memory // ""
    )
' nodes.json 2>/dev/null \
| while read -r nodeName cpuAlloc memAlloc; do
    cpu_mc="$(convert_cpu_to_millicores "$cpuAlloc")"
    mem_ki="$(convert_memory_to_ki "$memAlloc")"
    echo "$nodeName $cpu_mc $mem_ki" >> node_alloc.txt
  done

# 4) Build arrays for node capacity
declare -A NODE_CPU_ALLOC
declare -A NODE_MEM_ALLOC

while read -r line; do
  node_name="$(echo "$line" | awk '{print $1}')"
  node_cpu="$(echo "$line" | awk '{print $2}')"
  node_mem="$(echo "$line" | awk '{print $3}')"
  NODE_CPU_ALLOC["$node_name"]="$node_cpu"
  NODE_MEM_ALLOC["$node_name"]="$node_mem"
done < node_alloc.txt

# 5) Fetch Pods
kubectl get pods --all-namespaces --context "$context" -o json > allpods.json 2>/dev/null

# 6) Dump each pod’s containers’ CPU/Memory to file pods.tmp
jq -r '
  .items[]
  | (
      (.metadata.namespace // "") + "\t" +
      (.metadata.name // "") + "\t" +
      (.spec.nodeName // "") + "\t" +
      (
        [ (.spec.containers[]? | (.resources.limits.cpu // "0")) ] 
        | join(",")
      ) + "\t" +
      (
        [ (.spec.containers[]? | (.resources.limits.memory // "0")) ]
        | join(",")
      )
    )
' allpods.json 2>/dev/null > pods.tmp

# 7) Compare totals
total_overlimit=0
threshold_fraction="$(awk -v p="$percentage" 'BEGIN {printf "%f", p / 100}')"

while IFS=$'\t' read -r namespace podname nodename cpulimits memlimits; do

  # If not scheduled, skip
  if [ -z "$nodename" ]; then
    continue
  fi

  node_cpu_alloc="${NODE_CPU_ALLOC[$nodename]}"
  node_mem_alloc="${NODE_MEM_ALLOC[$nodename]}"

  if [ -z "$node_cpu_alloc" ] || [ -z "$node_mem_alloc" ]; then
    continue
  fi

  node_cpu_threshold="$(awk -v c="$node_cpu_alloc" -v t="$threshold_fraction" 'BEGIN {printf "%.0f", c * t}')"
  node_mem_threshold="$(awk -v m="$node_mem_alloc" -v t="$threshold_fraction" 'BEGIN {printf "%.0f", m * t}')"

  # Sum all container CPU/Memory in the Pod
  IFS=',' read -r -a cpu_arr <<< "$cpulimits"
  IFS=',' read -r -a mem_arr <<< "$memlimits"

  total_pod_cpu=0
  total_pod_mem=0

  idx=0
  for cpuVal in "${cpu_arr[@]}"; do
    # Convert CPU
    cpu_needed="$(convert_cpu_to_millicores "$cpuVal")"
    if [ -n "$cpu_needed" ] && [ "$cpu_needed" -gt 0 ]; then
      total_pod_cpu="$((total_pod_cpu + cpu_needed))"
    fi

    # Convert Memory (matching array index)
    memVal="${mem_arr[$idx]}"
    mem_needed="$(convert_memory_to_ki "$memVal")"
    if [ -n "$mem_needed" ] && [ "$mem_needed" -gt 0 ]; then
      total_pod_mem="$((total_pod_mem + mem_needed))"
    fi
    idx="$((idx + 1))"
  done

  # Compare entire Pod's CPU/Memory to node threshold
  pod_exceeds="false"
  if [ "$total_pod_cpu" -gt "$node_cpu_threshold" ] || [ "$total_pod_mem" -gt "$node_mem_threshold" ]; then
    pod_exceeds="true"
  fi

  if [ "$pod_exceeds" = "true" ]; then
    total_overlimit="$((total_overlimit + 1))"
    echo -e "$namespace\t$podname\t$nodename\t${total_pod_cpu}/${node_cpu_alloc} CPU\t${total_pod_mem}/${node_mem_alloc} MEM" \
      >> pod_overlimits.txt
  fi

done < pods.tmp

# 8) Final Output
if [ "$total_overlimit" -gt 0 ]; then
  echo "PODS EXCEEDING ${percentage}% OF NODE CAPACITY (summed CPU & Memory):"
  echo "--------------------------------------------------------------------------------"
  echo -e "NAMESPACE\tPOD\tNODE\tCPU (mc used/cap)\tMEM (Ki used/cap)"
  echo "--------------------------------------------------------------------------------"
  cat pod_overlimits.txt
  echo "--------------------------------------------------------------------------------"
  echo "Total pods flagged: $total_overlimit"
else
  echo "No Pods detected whose total CPU/Memory limits exceed ${percentage}% of their Node's capacity."
  echo "Total pods flagged: 0"
fi
