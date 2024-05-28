#!/bin/bash

# Environment Variables:
# NAMESPACE
# CONTEXT

CPU_PERCENT_THRESHOLD=95
MEM_PERCENT_THRESHOLD=100



# TODO: mixin pod restarts check

# Function that converts memory resource units to pure bytes
convert_memory_to_bytes() {
  local resource=$1
  local bytes=0
  if [[ $resource =~ ^[0-9]+Ki$ ]]; then
    bytes=$(( ${resource%Ki} * 1024 ))
  elif [[ $resource =~ ^[0-9]+Mi$ ]]; then
    bytes=$(( ${resource%Mi} * 1024 * 1024 ))
  elif [[ $resource =~ ^[0-9]+Gi$ ]]; then
    bytes=$(( ${resource%Gi} * 1024 * 1024 * 1024 ))
  elif [[ $resource =~ ^[0-9]+Ti$ ]]; then
    bytes=$(( ${resource%Ti} * 1024 * 1024 * 1024 * 1024 ))
  elif [[ $resource =~ ^[0-9]+Pi$ ]]; then
    bytes=$(( ${resource%Pi} * 1024 * 1024 * 1024 * 1024 * 1024 ))
  elif [[ $resource =~ ^[0-9]+Ei$ ]]; then
    bytes=$(( ${resource%Ei} * 1024 * 1024 * 1024 * 1024 * 1024 * 1024 ))
  elif [[ $resource =~ ^[0-9]+K$ ]]; then
    bytes=$(( ${resource%K} * 1000 ))
  elif [[ $resource =~ ^[0-9]+M$ ]]; then
    bytes=$(( ${resource%M} * 1000 * 1000 ))
  elif [[ $resource =~ ^[0-9]+G$ ]]; then
    bytes=$(( ${resource%G} * 1000 * 1000 * 1000 ))
  elif [[ $resource =~ ^[0-9]+T$ ]]; then
    bytes=$(( ${resource%T} * 1000 * 1000 * 1000 * 1000 ))
  elif [[ $resource =~ ^[0-9]+P$ ]]; then
    bytes=$(( ${resource%P} * 1000 * 1000 * 1000 * 1000 * 1000 ))
  elif [[ $resource =~ ^[0-9]+E$ ]]; then
    bytes=$(( ${resource%E} * 1000 * 1000 * 1000 * 1000 * 1000 * 1000 ))
  else
    bytes=$resource
  fi
  echo $bytes
}

# Function that converts CPU resource units to milliCPU
convert_cpu_to_millicpu() {
  local resource=$1
  local millicpu=0
  if [[ $resource =~ ^[0-9]+m$ ]]; then
    millicpu=${resource%m}
  else
    millicpu=$(( resource * 1000 ))  # Convert whole CPU to milliCPU
  fi
  echo $millicpu
}

# Function that finds the owning resource of a pod and returns its name
get_owning_resource() {
  local pod_name=$1
  kubectl get pod $pod_name -o jsonpath='{.metadata.ownerReferences[0].name}'
}

# Function that gets the CPU and memory requests and limits of a given pod as JSON
get_pod_resources_config() {
  local pod_name=$1
  kubectl get --context $CONTEXT -n $NAMESPACE pod $pod_name -o jsonpath='{.spec.containers[*].resources}'
}

# Function that converts the output of kubectl top to JSON using protocol buffers
convert_top_to_json() {
  kubectl top --context $CONTEXT -n $NAMESPACE pods --use-protocol-buffers=true --no-headers | awk '
  BEGIN {
    print "["
  }
  {
    if (NR > 1) {
      print ","
    }
    print "  {"
    print "    \"name\": \"" $1 "\","
    print "    \"cpu\": \"" $2 "\","
    print "    \"memory\": \"" $3 "\""
    print "  }"
  }
  END {
    print "]"
  }'
}

main() {
    util_restarting_pods=()
    util_limit_pods=()
    echo "Starting $NAMESPACE Namespace Scan For Overutilized Pods"
    top_stats=$(convert_top_to_json)
    echo "$top_stats" | jq -c '.[]' | while read -r item; do
        name=$(echo "$item" | jq -r '.name')
        pod_restarts=$(kubectl get pod $name -n $NAMESPACE -o jsonpath='{.status.containerStatuses[0].restartCount}')
        cpu=$(echo "$item" | jq -r '.cpu')
        memory=$(echo "$item" | jq -r '.memory')
        used_memory_bytes=$(convert_memory_to_bytes $memory)
        used_cpu_millicpu=$(convert_cpu_to_millicpu $cpu)
        # parse config for resource reservation info
        resource_config=$(get_pod_resources_config $name)
        requests_cpu=$(echo "$resource_config" | jq -r '.requests.cpu')
        requests_memory=$(echo "$resource_config" | jq -r '.requests.memory')
        requests_mcpu=$(convert_cpu_to_millicpu $requests_cpu)
        requests_memory_bytes=$(convert_memory_to_bytes $requests_memory)

        limits_cpu=$(echo "$resource_config" | jq -r '.limits.cpu')
        limits_memory=$(echo "$resource_config" | jq -r '.limits.memory')
        limits_mcpu=$(convert_cpu_to_millicpu $limits_cpu)
        limits_memory_bytes=$(convert_memory_to_bytes $limits_memory)

        requests_cpu_utilization=$(( used_cpu_millicpu * 100 / requests_mcpu ))
        requests_memory_utilization=$(( used_memory_bytes * 100 / requests_memory_bytes ))
        limits_cpu_utilization=$(( used_cpu_millicpu * 100 / limits_mcpu ))
        limits_memory_utilization=$(( used_memory_bytes * 100 / limits_memory_bytes ))

        echo "Name: $name, Restarts: $pod_restarts, CPU: $cpu, Memory: $memory , mCPU: $used_cpu_millicpu, Memory Bytes: $used_memory_bytes, CPU % Utilization: $requests_cpu_utilization%, Memory % Utilization: $requests_memory_utilization%"
        if [ $requests_cpu_utilization -gt $CPU_PERCENT_THRESHOLD ] && [ $pod_restarts -gt 0 ]; then
            echo "Error: Pod $name has $requests_cpu_utilization% CPU utilization and restarts"
            util_restarting_pods+=("$name")
        fi
        if [ $requests_memory_utilization -gt $MEM_PERCENT_THRESHOLD ] && [ $pod_restarts -gt 0 ]; then
            echo "Error: Pod $name has $requests_memory_utilization% memory utilization and restarts"
            util_restarting_pods+=("$name")
        fi
        if [ $limits_cpu_utilization -gt $CPU_PERCENT_THRESHOLD ]; then
            echo "Error: Pod $name is at CPU limit $limits_cpu"
            util_limit_pods+=("$name")
        fi
        if [ $limits_memory_utilization -gt $MEM_PERCENT_THRESHOLD ]; then
            echo "Error: Pod $name is at memory limit $limits_memory"
            util_limit_pods+=("$name")
        fi
    done
    if [ ${#util_restarting_pods[@]} -gt 0 ]; then
        echo ""
        echo "Pods overutilized and restarting:"
        echo ${util_restarting_pods[@]}
    fi
    if [ ${#util_limit_pods[@]} -gt 0 ]; then
        echo ""
        echo "Pods at limits:"
        echo ${util_limit_pods[@]}
    fi
}

main