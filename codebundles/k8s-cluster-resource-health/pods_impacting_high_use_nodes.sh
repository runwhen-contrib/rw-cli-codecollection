#!/bin/bash

# Define thresholds: in millicores for CPU, and in MiB for Memory
CPU_USAGE_MIN="${CPU_USAGE_MIN:-100}"   # default 100m
MEM_USAGE_MIN="${MEM_USAGE_MIN:-100}"   # default 100Mi

# ... your existing script / commands ...

# Normalize units and compare
jq -s --arg cpuMin "$CPU_USAGE_MIN" \
      --arg memMin "$MEM_USAGE_MIN" '
  [
    # alias as $usage for top pods, $requests for resource requests
    .[0][] as $usage |
    .[1][] |
    # Match usage to requests by namespace/pod
    select(.pod == $usage.pod and .namespace == $usage.namespace)
    |
    {
      pod: .pod,
      namespace: .namespace,
      node: .nodeName,
      cpu_usage:    $usage.cpu_usage,
      cpu_request:  .cpu_request,
      memory_usage: $usage.memory_usage,
      memory_request: .memory_request,

      cpu_usage_millicores: (
        # Convert CPU usage to millicores
        $usage.cpu_usage |
        if test("m$") then
          rtrimstr("m") | tonumber
        else
          (tonumber * 1000)
        end
      ),

      cpu_request_millicores: (
        # Convert CPU request to millicores
        .cpu_request |
        if test("m$") then
          rtrimstr("m") | tonumber
        else
          (tonumber * 1000)
        end
      ),

      memory_usage_mib: (
        # Normalize memory usage to MiB
        $usage.memory_usage |
        if test("Gi$") then
          (rtrimstr("Gi") | tonumber * 1024)
        elif test("G$") then
          (rtrimstr("G")  | tonumber * 1024)
        elif test("Mi$") then
          rtrimstr("Mi") | tonumber
        elif test("M$") then
          rtrimstr("M") | tonumber
        else
          (tonumber)
        end
      ),

      memory_request_mib: (
        .memory_request |
        if test("Gi$") then
          (rtrimstr("Gi") | tonumber * 1024)
        elif test("G$") then
          (rtrimstr("G")  | tonumber * 1024)
        elif test("Mi$") then
          rtrimstr("Mi") | tonumber
        elif test("M$") then
          rtrimstr("M") | tonumber
        else
          (tonumber)
        end
      )
    }
    # Now we filter based on usage vs request, AND usage thresholds
    | . + {
        cpu_usage_exceeds: (.cpu_usage_millicores > .cpu_request_millicores),
        memory_usage_exceeds: (.memory_usage_mib > .memory_request_mib)
      }
    # Filter 1: only pods that exceed CPU or Memory requests
    | select(.cpu_usage_exceeds or .memory_usage_exceeds)
    # Filter 2 (new): exclude pods that are under the usage thresholds
    | select(.cpu_usage_millicores >= ($cpuMin | tonumber))
    | select(.memory_usage_mib >= ($memMin | tonumber))
  ]
  # group results by namespace for final structure
  | group_by(.namespace)
  | map({ (.[0].namespace): .})
  | add
' pod_usage.json pod_requests.json > pods_exceeding_requests.json


cat pods_exceeding_requests.json | jq -r '
  # Print a header row first:
  (["NAMESPACE","POD","NODE","CPU_USAGE","CPU_REQUEST","CPU_EXCEEDS","MEMORY_USAGE","MEMORY_REQUEST","MEMORY_EXCEEDS"] | @tsv),

  # The JSON is an object whose keys are namespaces and values are arrays of objects.
  # We transform each object into a TSV line:
  to_entries[] as $ns |
  $ns.value[] |
  [
    $ns.key,                        # namespace
    .pod,                           # pod
    .node,                          # node
    .cpu_usage,                     # CPU usage (e.g., 500m)
    .cpu_request,                   # CPU request (e.g., 400m)
    (.cpu_usage_exceeds|tostring),  # true/false
    .memory_usage,                  # memory usage (e.g., 123Mi)
    .memory_request,                # memory request (e.g., 100Mi)
    (.memory_usage_exceeds|tostring)
  ] | @tsv
' | column -t