#!/usr/bin/env bash
# Fetches recent scheduler pod logs and flags common DAG import / traceback patterns.
set -euo pipefail
set -x

: "${CONTEXT:?}" "${NAMESPACE:?}"

OUTPUT_FILE="${OUTPUT_FILE:-sample_airflow_scheduler_logs_issues.json}"
KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
LABEL_SEL="${AIRFLOW_LABEL_SELECTOR:-app.kubernetes.io/name=airflow}"
LW="${RW_LOOKBACK_WINDOW:-1h}"

if [[ "$LW" =~ ^([0-9]+)h$ ]]; then SINCE="${BASH_REMATCH[1]}h"
elif [[ "$LW" =~ ^([0-9]+)m$ ]]; then SINCE="${BASH_REMATCH[1]}m"
else SINCE="1h"
fi

sched_pod=$("${KUBECTL}" get pods -n "${NAMESPACE}" --context "${CONTEXT}" -l "${LABEL_SEL}" -o json 2>/dev/null | \
  jq -r '[.items[]? | select(.metadata.name | test("scheduler"; "i")) | .metadata.name] | first // empty')

if [[ -z "$sched_pod" ]]; then
  sched_pod=$("${KUBECTL}" get pods -n "${NAMESPACE}" --context "${CONTEXT}" -l "${LABEL_SEL},component=scheduler" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi

if [[ -z "$sched_pod" ]]; then
  echo '[{"title":"No Airflow scheduler pod found","details":"Could not find a pod with scheduler in the name or component=scheduler under the Airflow label selector.","severity":3,"next_steps":"Adjust AIRFLOW_LABEL_SELECTOR or confirm the chart labels for the scheduler."}]' | jq . > "$OUTPUT_FILE"
  echo "No scheduler pod found."
  exit 0
fi

if ! log_out=$("${KUBECTL}" logs -n "${NAMESPACE}" --context "${CONTEXT}" "$sched_pod" --since="${SINCE}" --tail=300 2>&1); then
  issues_json=$(jq -n --arg d "$log_out" ' [{
    "title": "Cannot read scheduler logs",
    "details": $d,
    "severity": 4,
    "next_steps": "Verify RBAC for pods/log and pod state (running vs pending)."
  } ]')
  echo "$issues_json" | jq . > "$OUTPUT_FILE"
  echo "kubectl logs failed."
  exit 0
fi

issues_json='[]'
if echo "$log_out" | grep -qiE 'Traceback|ImportError|ModuleNotFoundError|DAG.*import|Broken DAG|SyntaxError'; then
  det=$(echo "$log_out" | grep -iE 'Traceback|ImportError|ModuleNotFoundError|DAG.*import|Broken DAG|SyntaxError' | head -20 || true)
  issues_json=$(echo "$issues_json" | jq \
    --arg title "DAG import or Python errors in scheduler logs (\`${sched_pod}\`)" \
    --arg details "$det" \
    '. + [{
      "title": $title,
      "details": $details,
      "severity": 4,
      "next_steps": "Fix DAG package dependencies and syntax; validate imports in a dev environment."
    }]')
fi

if echo "$log_out" | grep -qiE 'DatabaseError|could not connect|timeout.*postgres|MySQL.*lost connection'; then
  det=$(echo "$log_out" | grep -iE 'DatabaseError|could not connect|timeout.*postgres|MySQL' | head -10 || true)
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Database connectivity errors in scheduler logs (\`${sched_pod}\`)" \
    --arg details "$det" \
    '. + [{
      "title": $title,
      "details": $details,
      "severity": 3,
      "next_steps": "Check metadata DB reachability and credentials (see postgres health bundle)."
    }]')
fi

echo "$issues_json" | jq . > "$OUTPUT_FILE"

printf '%s\n' "--- Scheduler log sample (${sched_pod}, since ${SINCE}) ---"
echo "$log_out" | tail -80
