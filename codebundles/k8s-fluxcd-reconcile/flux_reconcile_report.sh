#!/bin/bash

# Define the namespace
FLUX_NAMESPACE="flux-system"
SINCE_TIME="1h"
TRUNCATE_LINES=5
MAX_LINES=500

controllers=$(kubectl get deploy -oname --no-headers -n $FLUX_NAMESPACE | grep -i controller)

echo "Generating reconcile report for Flux controllers in namespace $FLUX_NAMESPACE"
echo "For controllers: $controllers"
echo ""
total_errors=0
echo "---------------------------------------------"
for controller in $controllers; do
    echo "$controller Controller Summary"
    recent_logs=$(kubectl logs $controller -n $FLUX_NAMESPACE --tail=$MAX_LINES --since=$SINCE_TIME)
    error_logs=$(echo "$recent_logs" | grep -i "\"level\":\"error\"")
    info_logs=$(echo "$recent_logs" | grep -i "\"level\":\"info\"")
    error_count=$(echo "$error_logs" | grep -v '^$' | wc -l)
    total_errors=$((total_errors + error_count))
    echo "Errors encountered: $error_count"
    echo ""
    echo ""
    if [ $error_count -gt 0 ]; then
        echo "Recent Error Logs:"
        echo "$error_logs" | head -n $TRUNCATE_LINES
        echo ""
        echo ""
        echo "Recent Info Logs:"
        echo "$info_logs" | head -n $TRUNCATE_LINES
    fi
    echo "---------------------------------------------"
done
echo ""
echo ""
echo "Total Errors for All Controllers: $total_errors"
echo "---------------------------------------------"
if [ $total_errors -gt 0 ]; then
    exit 1
fi
exit 0