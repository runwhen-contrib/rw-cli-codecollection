#!/usr/bin/env bash
set -euo pipefail
set -x

: "${OPENROUTER_API_KEY:?Must set OPENROUTER_API_KEY}"
: "${OPENROUTER_BUDGET_USD:=0}"

OUTPUT_FILE="budget_issues.json"
issues_json='[]'

echo "Checking OpenRouter budget status..."

if ! api_response=$(curl -s --max-time 30 \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" \
  "https://openrouter.ai/api/v1/auth/key" 2>err.log); then
    err_msg=$(cat err.log)
    rm -f err.log
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Cannot Reach OpenRouter API for Budget Check" \
      --arg details "API call to /api/v1/auth/key failed: $err_msg" \
      --arg severity "4" \
      --arg next_steps "Verify network connectivity and OpenRouter API availability" \
      '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 0
fi
rm -f err.log

credits=$(echo "$api_response" | jq -r '.credits // "0"')
usage=$(echo "$api_response" | jq -r '.usage // "0"')

budget=$(echo "$OPENROUTER_BUDGET_USD" | jq -r '. // 0')
budget_disabled=$(echo "$budget == 0" | bc -l)

echo "Account: remaining=$credits, lifetime_usage=$usage, budget=$budget"

if [ "$budget_disabled" -eq 1 ]; then
    echo "Budget checking is disabled (budget=0). Skipping budget checks."
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 0
fi

if [ "$(echo "$usage > $budget" | bc -l)" -eq 1 ]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "OpenRouter Budget Exceeded" \
      --arg details "Lifetime spend of \$$usage exceeds the configured budget of \$$budget. Remaining credits: \$$credits." \
      --arg severity "4" \
      --arg next_steps "Review spending and increase the budget or reduce usage. Consider setting up spending alerts at https://openrouter.ai/settings/limits." \
      '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
fi

combined_spend=$(echo "$usage + $credits" | bc -l)
if [ "$(echo "$combined_spend > 0" | bc -l)" -eq 1 ]; then
    burn_rate=$(echo "$usage / $combined_spend * 100" | bc -l)
    if [ "$(echo "$burn_rate > 80" | bc -l)" -eq 1 ]; then
        issues_json=$(echo "$issues_json" | jq \
          --arg title "OpenRouter Budget Depletion Risk" \
          --arg details "Lifetime spend of \$$usage represents ${burn_rate}% of total credits loaded. Budget remaining may not last until the next reset period." \
          --arg severity "3" \
          --arg next_steps "Add funds proactively to avoid service interruption. Consider increasing the budget or reducing spend." \
          '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    fi
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Budget check completed. Results saved to $OUTPUT_FILE"