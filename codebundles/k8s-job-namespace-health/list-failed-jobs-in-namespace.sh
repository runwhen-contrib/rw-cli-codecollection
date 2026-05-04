#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Lists Jobs in Failed condition, backoff exhaustion, and unhealthy pods.
# Writes JSON issues to LIST_FAILED_JOBS_ISSUES_FILE.
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

BIN="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
OUTPUT_FILE="${LIST_FAILED_JOBS_ISSUES_FILE:-list_failed_jobs_issues.json}"
issues_json='[]'

if ! jobs_json=$("$BIN" get jobs -n "$NAMESPACE" --context "$CONTEXT" -o json 2>err.log); then
  err_msg=$(cat err.log || true)
  rm -f err.log
  issues_json=$(echo "$issues_json" | jq -n \
    --arg title "Cannot List Jobs in Namespace \`$NAMESPACE\`" \
    --arg details "$err_msg" \
    --argjson severity 4 \
    --arg next_steps "Fix kubeconfig/context/RBAC for jobs in namespace" \
    '[{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  echo "list-failed-jobs: cannot list Jobs (context \`${CONTEXT}\`, namespace \`${NAMESPACE}\`)."
  echo "kubectl error: ${err_msg}"
  echo "Wrote ${OUTPUT_FILE} ($(echo "$issues_json" | jq 'length') issue(s))."
  exit 0
fi
rm -f err.log

pods_json=$("$BIN" get pods -n "$NAMESPACE" --context "$CONTEXT" -o json 2>/dev/null || echo '{"items":[]}')

# Per-job failure analysis via jq, emit issue objects as JSON lines then slurp
while IFS= read -r line; do
  [[ -z "$line" || "$line" == "null" ]] && continue
  issues_json=$(echo "$issues_json" | jq --argjson obj "$line" '. += [$obj]')
done < <(echo "$jobs_json" | jq -c --arg ns "$NAMESPACE" '
  .items[] |
  .metadata.name as $jn |
  .spec.backoffLimit as $bl |
  (.status.failed // 0) as $fc |
  (.status.conditions // []) as $conds |
  ([$conds[] | select(.type=="Failed" and .status=="True")] | length > 0) as $failed_cond |
  ([$conds[] | select(.type=="Failed") | .reason // ""] | any(test("BackoffLimitExceeded"; "i"))) as $backoff_reason |
  ($bl != null and $fc > $bl) as $past_bl |
  if ($failed_cond or $past_bl or $backoff_reason) then
    {
      title: ("Job `" + $jn + "` failed in namespace `" + $ns + "`"),
      details: (
        "Failed condition: \($failed_cond)\n" +
        "Failures reported: \($fc), backoffLimit: \($bl // "null")\n" +
        "Condition messages: \($conds | map(select(.type=="Failed")) | map(.message // .reason) | join("; "))"
      ),
      severity: (if ($failed_cond and ($fc > 0)) then 2 else 3 end),
      next_steps: "kubectl describe job \($jn) -n \($ns); kubectl logs -l job-name=\($jn) -n \($ns) --all-containers=true --tail=200"
    }
  else empty end
')

# Pod-level container failures for job pods
while IFS= read -r line; do
  [[ -z "$line" || "$line" == "null" ]] && continue
  issues_json=$(echo "$issues_json" | jq --argjson obj "$line" '. += [$obj]')
done < <(echo "$pods_json" | jq -c --arg ns "$NAMESPACE" '
  .items[]
  | select([.metadata.ownerReferences[]? | select(.kind=="Job")] | length > 0)
  | .metadata.name as $pod
  | ([.metadata.ownerReferences[] | select(.kind=="Job") | .name][0]) as $jobn
  | (.status.containerStatuses // [])[]
  | select(.state.waiting != null or (.state.terminated != null and (.state.terminated.exitCode // 0) != 0))
  | {
      title: ("Container issue for Job pod `" + $pod + "` (job `" + $jobn + "`) in `" + $ns + "`"),
      details:
        ("container: " + .name + "\n" +
         "waiting: " + ((.state.waiting // {}) | tostring) + "\n" +
         "terminated: " + ((.state.terminated // {}) | tostring)),
      severity: 3,
      next_steps: ("kubectl logs " + $pod + " -n " + $ns + " --all-containers=true --tail=200; kubectl describe pod " + $pod + " -n " + $ns)
    }
')

job_count=$(echo "$jobs_json" | jq '.items | length')
jobpod_count=$(echo "$pods_json" | jq '[.items[] | select([.metadata.ownerReferences[]? | select(.kind=="Job")] | length > 0)] | length')
issue_count=$(echo "$issues_json" | jq 'length')

echo "Context: CONTEXT=${CONTEXT} NAMESPACE=${NAMESPACE}"
echo "Scanned: ${job_count} Job(s), ${jobpod_count} Job-owned Pod object(s) (container status checked)."
if [[ "$issue_count" -eq 0 ]]; then
  echo "Result: No failed-condition Jobs, backoff-limit exhaustion, or unhealthy job-pod container states matched the checks."
else
  echo "Result: ${issue_count} finding(s) recorded as issues (per-Job and/or per Job pod). See RunWhen issues and ${OUTPUT_FILE}."
fi
echo "$issues_json" > "$OUTPUT_FILE"
echo "Wrote ${OUTPUT_FILE} (${issue_count} issue(s))."
