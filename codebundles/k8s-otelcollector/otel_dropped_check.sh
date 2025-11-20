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

    observed_at=$(echo "$output" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z?' | sort -r | head -1)
    
    if [ -z "$observed_at" ]; then
        last_line=$(echo "$output" | tail -1)
        observed_at=$(echo "$last_line" | awk '{print $1}')
    fi
    
    echo -E "Observed At: $observed_at"
    exit 1
fi
exit 0