#!/bin/bash
set -euo pipefail
# Display top 5 projects by cost from JSON report

if [ -f "gcp_cost_report.json" ]; then
    echo ""
    echo "💰 Top 5 Projects by Cost:"
    jq -r '.projects[0:5] | .[] | "  • " + .projectName + ": $" + ((.totalCost * 100 | round) / 100 | tostring)' gcp_cost_report.json 2>/dev/null || echo "  (Unable to parse JSON report)"
else
    echo "  (JSON report not generated)"
fi



