#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Summarizes batch/v1 Jobs in NAMESPACE: active, succeeded, failed counts and
# long-running active Jobs. Writes JSON issues to SUMMARIZE_JOBS_ISSUES_FILE.
# Env: CONTEXT, NAMESPACE, KUBERNETES_DISTRIBUTION_BINARY, RW_LOOKBACK_WINDOW,
#      JOB_ACTIVE_DURATION_WARN_MINUTES (minutes, integer string)
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

BIN="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
WARN_MINUTES="${JOB_ACTIVE_DURATION_WARN_MINUTES:-360}"
OUTPUT_FILE="${SUMMARIZE_JOBS_ISSUES_FILE:-summarize_jobs_issues.json}"
issues_json='[]'

if ! jobs_json=$("$BIN" get jobs -n "$NAMESPACE" --context "$CONTEXT" -o json 2>err.log); then
  err_msg=$(cat err.log || true)
  rm -f err.log
  issues_json=$(echo "$issues_json" | jq -n \
    --arg title "Cannot List Jobs in Namespace \`$NAMESPACE\`" \
    --arg details "kubectl get jobs failed: $err_msg" \
    --argjson severity 4 \
    --arg next_steps "Verify kubeconfig RBAC for jobs.batch in this namespace and that CONTEXT is correct" \
    '[{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  echo "ERROR listing jobs: $err_msg"
  exit 0
fi
rm -f err.log 2>/dev/null || true

stats=$(echo "$jobs_json" | jq --argjson warn "$WARN_MINUTES" '
  [.items[]] as $items |
  {
    total: ($items | length),
    active: [$items[] | select((.status.active // 0) > 0)] | length,
    succeeded: [$items[] | select([.status.conditions[]? | select(.type=="Complete" and .status=="True")] | length > 0)] | length,
    failed_terminal: [$items[] | select([.status.conditions[]? | select(.type=="Failed" and .status=="True")] | length > 0)] | length,
    long_active: [$items[] | select((.status.active // 0) > 0) | select(
      ((.status.startTime // "") | length) > 0
      and (((now - (.status.startTime | fromdateiso8601)) / 60) > ($warn | tonumber))
    )] | length,
    long_active_names: [$items[] | select((.status.active // 0) > 0) | select(
      ((.status.startTime // "") | length) > 0
      and (((now - (.status.startTime | fromdateiso8601)) / 60) > ($warn | tonumber))
    ) | .metadata.name] | join(", ")
  }
')

echo "Job summary stats: $stats"

failed_n=$(echo "$stats" | jq '.failed_terminal')
long_n=$(echo "$stats" | jq '.long_active')
active_n=$(echo "$stats" | jq '.active')
total=$(echo "$stats" | jq '.total')
long_names=$(echo "$stats" | jq -r '.long_active_names // ""')

if [[ "$failed_n" -gt 0 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Failed Jobs Present in Namespace \`$NAMESPACE\`" \
    --arg details "Found $failed_n Job(s) in Failed condition (of $total total). Active: $active_n. See list-failed task for details." \
    --argjson severity 3 \
    --arg next_steps "Inspect failed Job pods (kubectl describe job, kubectl logs), fix workload or backoff settings" \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
fi

if [[ "$long_n" -gt 0 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Long-Running Active Jobs in Namespace \`$NAMESPACE\`" \
    --arg details "$long_n active Job(s) exceed ${WARN_MINUTES}m runtime (startTime-based): ${long_names:-unknown}" \
    --argjson severity 4 \
    --arg next_steps "Check pod logs and events; confirm Job should still be running; investigate stuck workers or image pulls" \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
fi

if [[ "$total" -gt 0 && "$active_n" -gt 10 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "High Active Job Concurrency in Namespace \`$NAMESPACE\`" \
    --arg details "Namespace has $active_n active Jobs out of $total total — elevated batch surface area for incidents." \
    --argjson severity 4 \
    --arg next_steps "Review scheduler pressure, quota, and dependency queues if concurrency is unintended" \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
