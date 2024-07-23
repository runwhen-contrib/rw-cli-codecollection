#!/bin/bash

# ENV:
# CONTEXT
# NAMESPACE
# METRICS_PORT
# WORKLOAD_NAME
# WORKLOAD_SERVICE

output=$(kubectl --context $CONTEXT -n $NAMESPACE logs $WORKLOAD_SERVICE --since=60m --all-containers=true | grep error)
if [ -n "$output" ]; then
    echo -E "Error(s) Found:\n\n$output"
    exit 1
fi
exit 0