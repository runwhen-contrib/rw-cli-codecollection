#!/bin/bash

# ENV:
# CONTEXT
# NAMESPACE
# METRICS_PORT
# WORKLOAD_NAME
# WORKLOAD_SERVICE
since=60m
output=$(kubectl --context $CONTEXT -n $NAMESPACE logs service/$WORKLOAD_SERVICE --since=$since --all-containers=true | grep dropped -A 20)
if [ -n "$output" ]; then
    echo -E "Dropped Spans Found:"
    echo -E "$output"
    exit 1
fi
exit 0