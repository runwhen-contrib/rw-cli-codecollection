#!/bin/bash

# ENV:
# CONTEXT
# NAMESPACE
# METRICS_PORT
# WORKLOAD_NAME
# WORKLOAD_SERVICE
since=60m
output=$(kubectl --context $CONTEXT -n $NAMESPACE logs service/$WORKLOAD_SERVICE --since=$since --all-containers=true | grep error)
if [ -n "$output" ]; then
    echo -E "Error(s) Found:"
    echo -E "$output"
    
    last_line=$(echo "$output" | tail -1)
    observed_at=$(echo "$last_line" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})?' | head -1)
    if [ -z "$observed_at" ]; then
        observed_at=$(echo "$last_line" | awk '{print $1}')
    fi
    
    echo -E "Observed At: $observed_at"
    exit 1
fi
exit 0