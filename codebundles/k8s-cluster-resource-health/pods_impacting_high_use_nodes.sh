#!/bin/bash

# Define Kubernetes binary and context with dynamic defaults
KUBERNETES_DISTRIBUTION_BINARY="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}" # Default to 'kubectl' if not set in the environment
DEFAULT_CONTEXT=$(${KUBERNETES_DISTRIBUTION_BINARY} config current-context)
CONTEXT="${CONTEXT:-$DEFAULT_CONTEXT}" # Use environment variable or the current context from kubectl

process_nodes_and_usage() {
    # Get Node Details including allocatable resources
    nodes=$(${KUBERNETES_DISTRIBUTION_BINARY} get nodes --context ${CONTEXT} -o json | jq '[.items[] | {
        name: .metadata.name,
        cpu_allocatable: (.status.allocatable.cpu | rtrimstr("m") | tonumber),
        memory_allocatable: (.status.allocatable.memory | gsub("Ki"; "") | tonumber / 1024)
    }]')

    # Fetch node usage details
    usage=$(${KUBERNETES_DISTRIBUTION_BINARY} top nodes --context ${CONTEXT} | awk 'BEGIN { printf "[" } NR>1 { printf "%s{\"name\":\"%s\",\"cpu_usage\":\"%s\",\"memory_usage\":\"%s\"}", (NR>2 ? "," : ""), $1, ($2 == "<unknown>" ? "0" : $2), ($4 == "<unknown>" ? "0" : $4) } END { printf "]" }' | jq '.')

    # Combine and process the data
    jq -n --argjson nodes "$nodes" --argjson usage "$usage" '{
        nodes: $nodes | map({name: .name, cpu_allocatable: .cpu_allocatable, memory_allocatable: .memory_allocatable}),
        usage: $usage | map({name: .name, cpu_usage: (.cpu_usage | rtrimstr("m") | tonumber // 0), memory_usage: (.memory_usage | rtrimstr("Mi") | tonumber // 0)})
    } | .nodes as $nodes | .usage as $usage | 
    $nodes | map(
        . as $node | 
        $usage[] | 
        select(.name == $node.name) | 
        {
            name: .name, 
            cpu_utilization_percentage: (.cpu_usage / $node.cpu_allocatable * 100),
            memory_utilization_percentage: (.memory_usage / $node.memory_allocatable * 100)
        }
    ) | map(select(.cpu_utilization_percentage >= 90 or .memory_utilization_percentage >= 90))'
}


# Fetch pod resource requests
${KUBERNETES_DISTRIBUTION_BINARY} get pods --context ${CONTEXT} --all-namespaces -o json | jq -r '.items[] | {namespace: .metadata.namespace, pod: .metadata.name, nodeName: .spec.nodeName, cpu_request: (.spec.containers[].resources.requests.cpu // "0m"), memory_request: (.spec.containers[].resources.requests.memory // "0Mi")} | select(.cpu_request != "0m" and .memory_request != "0Mi")' | jq -s '.' > pod_requests.json



# Fetch current pod metrics
${KUBERNETES_DISTRIBUTION_BINARY} top pods --context ${CONTEXT} --all-namespaces --containers | awk 'BEGIN { printf "[" } NR>1 { printf "%s{\"namespace\":\"%s\",\"pod\":\"%s\",\"container\":\"%s\",\"cpu_usage\":\"%s\",\"memory_usage\":\"%s\"}", (NR>2 ? "," : ""), $1, $2, $3, $4, $5 } END { printf "]" }' | jq '.' > pod_usage.json



# Normalize units and compare
jq -s '[
    .[0][] as $usage | 
    .[1][] | 
    select(.pod == $usage.pod and .namespace == $usage.namespace) |
    {
        pod: .pod,
        namespace: .namespace,
        node: .nodeName,
        cpu_usage: $usage.cpu_usage,
        cpu_request: .cpu_request,
        cpu_usage_exceeds: (
            # Convert CPU usage to millicores, assuming all inputs need to be converted from milli-units if they end with 'm'
            ($usage.cpu_usage | 
                if test("m$") then rtrimstr("m") | tonumber 
                else tonumber * 1000 
                end
            ) > (
                # Convert CPU request to millicores, assuming it may already be in millicores if it ends with 'm'
                .cpu_request | 
                if test("m$") then rtrimstr("m") | tonumber 
                else tonumber * 1000 
                end
            )
        ),
        memory_usage: $usage.memory_usage,
        memory_request: .memory_request,
        memory_usage_exceeds: (
            # Normalize memory usage to MiB, handling MiB and GiB
            ($usage.memory_usage | 
                if test("Gi$") then rtrimstr("Gi") | tonumber * 1024
                elif test("G$") then rtrimstr("G") | tonumber * 1024
                elif test("Mi$") then rtrimstr("Mi") | tonumber
                elif test("M$") then rtrimstr("M") | tonumber
                else tonumber
                end
            ) > (
                # Normalize memory request to MiB
                .memory_request | 
                if test("Gi$") then rtrimstr("Gi") | tonumber * 1024
                elif test("G$") then rtrimstr("G") | tonumber * 1024
                elif test("Mi$") then rtrimstr("Mi") | tonumber
                elif test("M$") then rtrimstr("M") | tonumber
                else tonumber
                end
            )
        )
    }
    | select(.cpu_usage_exceeds or .memory_usage_exceeds)
] | group_by(.namespace) | map({(.[0].namespace): .}) | add' pod_usage.json pod_requests.json > pods_exceeding_requests.json

cat pods_exceeding_requests.json