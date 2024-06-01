#!/bin/bash

# Ensure KUBERNETES_DISTRIBUTION_BINARY, CONTEXT, NAMESPACE, UTILIZATION_THRESHOLD, and DEFAULT_INCREASE are set
if [[ -z "${KUBERNETES_DISTRIBUTION_BINARY}" || -z "${CONTEXT}" || -z "${NAMESPACE}" || -z "${UTILIZATION_THRESHOLD}" || -z "${DEFAULT_INCREASE}" ]]; then
  echo "KUBERNETES_DISTRIBUTION_BINARY, CONTEXT, NAMESPACE, UTILIZATION_THRESHOLD, and DEFAULT_INCREASE environment variables must be set."
  exit 1
fi

# Function to check if a pod has OOMKilled status or exit code 137
check_pod_status() {
  local pod_name=$1

  pod_status=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod "$pod_name" -n "${NAMESPACE}" --context ${CONTEXT} -o jsonpath='{.status.containerStatuses[*].state.terminated.reason}')
  exit_code=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod "$pod_name" -n "${NAMESPACE}" --context ${CONTEXT} -o jsonpath='{.status.containerStatuses[*].state.terminated.exitCode}')

  if [[ $pod_status == *"OOMKilled"* || $exit_code -eq 137 ]]; then
    echo true
  else
    echo false
  fi
}

# Initialize an empty array to store overutilized pods
overutilized_pods=()

# Get the list of pods and their resource usage in the specified namespace
pods=$(${KUBERNETES_DISTRIBUTION_BINARY} top pod -n "${NAMESPACE}" --context ${CONTEXT} --no-headers | awk '{print $1}')

# Loop through each pod
for pod in $pods; do
  # Get pod resource limits
  echo "---"
  echo "Processing Pod $pod"
  cpu_limit=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod "$pod" -n "${NAMESPACE}" --context ${CONTEXT} -o jsonpath='{.spec.containers[*].resources.limits.cpu}')
  mem_limit=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod "$pod" -n "${NAMESPACE}" --context ${CONTEXT} -o jsonpath='{.spec.containers[*].resources.limits.memory}')
  
  # Convert memory limit to Mi
  if [[ $mem_limit == *Gi ]]; then
    mem_limit=$(echo "$mem_limit" | sed 's/Gi//' | awk '{printf "%.0f", $1 * 1024}')
  elif [[ $mem_limit == *Mi ]]; then
    mem_limit=$(echo "$mem_limit" | sed 's/Mi//')
  fi

  # Convert CPU limit to millicores
  if [[ $cpu_limit == *m ]]; then
    cpu_limit=$(echo "$cpu_limit" | sed 's/m//')
  else
    cpu_limit=$(echo "$cpu_limit" | awk '{printf "%.0f", $1 * 1000}')
  fi

  # Handle cases where limits are not set (0 or empty)
  cpu_limit=${cpu_limit:-0}
  mem_limit=${mem_limit:-0}

  # Get pod current resource usage
  cpu_usage=$(${KUBERNETES_DISTRIBUTION_BINARY} top pod "$pod" -n "${NAMESPACE}" --context ${CONTEXT} --no-headers | awk '{print $2}' | sed 's/m//')
  mem_usage=$(${KUBERNETES_DISTRIBUTION_BINARY} top pod "$pod" -n "${NAMESPACE}" --context ${CONTEXT} --no-headers | awk '{print $3}' | sed 's/Mi//')
  echo "CPU Limit: $cpu_limit (m)"
  echo "CPU Usage: $cpu_usage (m)"
  echo "Memory Limit: $mem_limit (Mi)"
  echo "Memory Usage: $mem_usage (Mi)"

  # Calculate threshold values
  if [[ $cpu_limit -ne 0 ]]; then
    cpu_threshold=$(awk "BEGIN {printf \"%.0f\", $cpu_limit * $UTILIZATION_THRESHOLD / 100}")
  else
    cpu_threshold=0
  fi

  if [[ $mem_limit -ne 0 ]]; then
    mem_threshold=$(awk "BEGIN {printf \"%.0f\", $mem_limit * $UTILIZATION_THRESHOLD / 100}")
  else
    mem_threshold=0
  fi

  echo "CPU Threshold: $cpu_threshold (m)"
  echo "Memory Threshold: $mem_threshold (Mi)"

  # Check if the pod is overutilized
  reason=""
  if [[ $cpu_limit -ne 0 && $cpu_usage -gt $cpu_threshold ]]; then
    reason="CPU usage exceeds threshold"
  fi
  if [[ $mem_limit -ne 0 && $mem_usage -gt $mem_threshold ]]; then
    if [[ -n $reason ]]; then
      reason="$reason and memory usage exceeds threshold"
    else
      reason="Memory usage exceeds threshold"
    fi
  fi

  if [[ -n $reason ]]; then
    recommended_cpu_increase=$(awk "BEGIN {printf \"%.0f\", $cpu_limit * (1 + $DEFAULT_INCREASE / 100)}")
    recommended_mem_increase=$(awk "BEGIN {printf \"%.0f\", $mem_limit * (1 + $DEFAULT_INCREASE / 100)}")
    overutilized_pods+=("{\"namespace\":\"${NAMESPACE}\", \"pod\":\"$pod\", \"reason\":\"$reason\", \"cpu_usage\":\"$cpu_usage\", \"mem_usage\":\"$mem_usage\", \"cpu_limit\":\"$cpu_limit\", \"mem_limit\":\"$mem_limit\", \"cpu_threshold\":\"$cpu_threshold\", \"mem_threshold\":\"$mem_threshold\", \"recommended_cpu_increase\":\"$recommended_cpu_increase (m)\", \"recommended_mem_increase\":\"$recommended_mem_increase (Mi)\"}")
  fi

  # Check if the pod has an exit code of 137 or OOMKilled status
  if [[ $(check_pod_status "$pod") == "true" ]]; then
    overutilized_pods+=("{\"namespace\":\"${NAMESPACE}\", \"pod\":\"$pod\", \"reason\":\"OOMKilled or exit code 137\", \"cpu_usage\":\"$cpu_usage\", \"mem_usage\":\"$mem_usage\", \"cpu_limit\":\"$cpu_limit\", \"mem_limit\":\"$mem_limit\"}")
  fi
done

# Convert the array to JSON format
json_output=$(printf '%s\n' "${overutilized_pods[@]}" | jq -s '.')

# Write the JSON output to a file
output_file="$HOME/overutilized_pods.json"
if [[ ${#overutilized_pods[@]} -eq 0 ]]; then
  echo "[]" > "$output_file"
else
  echo "$json_output" > "$output_file"
fi

# Print the JSON output
echo "$json_output"
