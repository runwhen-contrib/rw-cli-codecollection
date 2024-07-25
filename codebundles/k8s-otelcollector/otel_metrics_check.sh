#!/bin/bash

# ENV:
# CONTEXT
# NAMESPACE
# METRICS_PORT
# WORKLOAD_NAME
# WORKLOAD_SERVICE

THRESHOLD=500
rv=0
metrics=$(kubectl --context $CONTEXT -n $NAMESPACE exec $WORKLOAD_NAME -- curl $WORKLOAD_SERVICE:$METRICS_PORT/metrics)
queued_spans=$(echo -E "$metrics" | grep "otelcol_exporter_queue_size{")
while IFS= read -r line; do
    echo "$line"
    value=$(echo "$line" | awk '{print $2}')
    if [ "$value" -gt "$THRESHOLD" ]; then
        echo "Error: queued spans ($value) exceeds threshold ($THRESHOLD)"
        rv=1

    fi
done <<< "$queued_spans"
exit $rv