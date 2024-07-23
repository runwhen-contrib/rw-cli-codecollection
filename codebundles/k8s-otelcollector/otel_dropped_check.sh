#!/bin/bash

# ENV:
# CONTEXT
# NAMESPACE
# METRICS_PORT
# WORKLOAD_NAME
# WORKLOAD_SERVICE

output=$(kubectl --context $CONTEXT -n $NAMESPACE logs $WORKLOAD_SERVICE --since=60m --all-containers=true | grep dropped -A 20)
if [ -n "$output" ]; then
    echo -E "Dropped Spans Found:\n\n$output"
    exit 1
fi
exit 0