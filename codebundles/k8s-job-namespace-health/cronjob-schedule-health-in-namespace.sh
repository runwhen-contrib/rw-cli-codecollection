#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# CronJob reliability: suspended, recent schedule without success, latest child failed.
# RW_LOOKBACK_WINDOW sets freshness (e.g. 24h). Writes CRONJOB_HEALTH_ISSUES_FILE JSON.
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

BIN="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
OUTPUT_FILE="${CRONJOB_HEALTH_ISSUES_FILE:-cronjob_health_issues.json}"
LOOKBACK="${RW_LOOKBACK_WINDOW:-24h}"
issues_json='[]'

parse_lookback_seconds() {
  local s="${1:-24h}"
  s="${s// /}"
  if [[ "$s" =~ ^([0-9]+)h$ ]]; then echo $((${BASH_REMATCH[1]} * 3600)); return; fi
  if [[ "$s" =~ ^([0-9]+)m$ ]]; then echo $((${BASH_REMATCH[1]} * 60)); return; fi
  if [[ "$s" =~ ^([0-9]+)d$ ]]; then echo $((${BASH_REMATCH[1]} * 86400)); return; fi
  if [[ "$s" =~ ^([0-9]+)s$ ]]; then echo "${BASH_REMATCH[1]}"; return; fi
  if [[ "$s" =~ ^[0-9]+$ ]]; then echo $((${s#} * 3600)); return; fi
  echo 86400
}

AGE_SEC=$(parse_lookback_seconds "$LOOKBACK")

if ! cj_json=$("$BIN" get cronjobs -n "$NAMESPACE" --context "$CONTEXT" -o json 2>err.log); then
  err_msg=$(cat err.log || true)
  rm -f err.log
  issues_json=$(echo "$issues_json" | jq -n \
    --arg title "Cannot List CronJobs in Namespace \`$NAMESPACE\`" \
    --arg details "$err_msg" \
    --argjson severity 4 \
    --arg next_steps "Verify RBAC for cronjobs.batch" \
    '[{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  echo "cronjob-schedule-health: cannot list CronJobs (context \`${CONTEXT}\`, namespace \`${NAMESPACE}\`)."
  echo "kubectl error: ${err_msg}"
  echo "Wrote ${OUTPUT_FILE} ($(echo "$issues_json" | jq 'length') issue(s))."
  exit 0
fi
rm -f err.log

if ! jobs_json=$("$BIN" get jobs -n "$NAMESPACE" --context "$CONTEXT" -o json 2>err.log); then
  err_msg=$(cat err.log || true)
  rm -f err.log
  issues_json=$(echo "$issues_json" | jq -n \
    --arg title "Cannot List Jobs for CronJob Correlation in \`$NAMESPACE\`" \
    --arg details "$err_msg" \
    --argjson severity 4 \
    --arg next_steps "Verify RBAC for jobs.batch" \
    '[{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  echo "cronjob-schedule-health: cannot list Jobs for CronJob correlation (context \`${CONTEXT}\`, namespace \`${NAMESPACE}\`)."
  echo "kubectl error: ${err_msg}"
  echo "Wrote ${OUTPUT_FILE} ($(echo "$issues_json" | jq 'length') issue(s))."
  exit 0
fi
rm -f err.log

while IFS= read -r line; do
  [[ -z "$line" || "$line" == "null" ]] && continue
  issues_json=$(echo "$issues_json" | jq --argjson obj "$line" '. += [$obj]')
done < <(echo "$cj_json" | jq -c --arg ns "$NAMESPACE" '
  .items[] | select(.spec.suspend == true) |
  {
    title: ("CronJob `" + .metadata.name + "` is suspended in `" + $ns + "`"),
    details: ("schedule: " + (.spec.schedule // "unknown")),
    severity: 3,
    next_steps: ("If unintended, resume: kubectl patch cronjob " + .metadata.name + " -n " + $ns + " --type merge -p '{\"spec\":{\"suspend\":false}}'")
  }
')

while IFS= read -r line; do
  [[ -z "$line" || "$line" == "null" ]] && continue
  issues_json=$(echo "$issues_json" | jq --argjson obj "$line" '. += [$obj]')
done < <(echo "$cj_json" | jq -c --arg ns "$NAMESPACE" --argjson age "$AGE_SEC" '
  .items[] | select(.spec.suspend != true) |
  (.status.lastScheduleTime // null) as $ls |
  (.status.lastSuccessfulTime // null) as $lok |
  select($ls != null) |
  select((now - ($ls | fromdateiso8601)) <= $age) |
  select(
    $lok == null or
    (($lok | fromdateiso8601) < ($ls | fromdateiso8601))
  ) |
  {
    title: ("CronJob `" + .metadata.name + "` may lack recent success in `" + $ns + "`"),
    details: ("lastScheduleTime: \($ls), lastSuccessfulTime: \($lok // \"none\")"),
    severity: 4,
    next_steps: ("Review child Jobs and logs: kubectl get jobs -n \($ns) --selector=cronjob.kubernetes.io/name=" + .metadata.name)
  }
')

while IFS= read -r line; do
  [[ -z "$line" || "$line" == "null" ]] && continue
  issues_json=$(echo "$issues_json" | jq --argjson obj "$line" '. += [$obj]')
done < <(echo "$jobs_json" | jq -c --arg ns "$NAMESPACE" '
  [.items[] | select([.metadata.ownerReferences[]? | select(.kind=="CronJob")] | length > 0)]
  | group_by([.metadata.ownerReferences[] | select(.kind=="CronJob") | .name][0])
  | map(sort_by(.metadata.creationTimestamp) | last)
  | .[]
  | select([.status.conditions[]? | select(.type=="Failed" and .status=="True")] | length > 0)
  | (.metadata.ownerReferences[] | select(.kind=="CronJob") | .name) as $cj
  | .metadata.name as $jn
  | {
      title: ("Latest Job `" + $jn + "` for CronJob `" + $cj + "` failed in `" + $ns + "`"),
      details: ("conditions: " + ((.status.conditions // []) | tostring)),
      severity: 3,
      next_steps: ("kubectl logs job/" + $jn + " -n " + $ns + " --all-containers=true --tail=300")
    }
')

cj_total=$(echo "$cj_json" | jq '.items | length')
cj_suspended=$(echo "$cj_json" | jq '[.items[] | select(.spec.suspend == true)] | length')
jobs_total=$(echo "$jobs_json" | jq '.items | length')
cronjob_child_jobs=$(echo "$jobs_json" | jq '[.items[] | select([.metadata.ownerReferences[]? | select(.kind=="CronJob")] | length > 0)] | length')
issue_count=$(echo "$issues_json" | jq 'length')

echo "$issues_json" > "$OUTPUT_FILE"
echo "Context: CONTEXT=${CONTEXT} NAMESPACE=${NAMESPACE} lookback=${LOOKBACK} (${AGE_SEC}s)"
echo "CronJobs: ${cj_total} total (${cj_suspended} suspended) | Jobs in namespace: ${jobs_total} (${cronjob_child_jobs} owned by a CronJob)"
if [[ "$issue_count" -eq 0 ]]; then
  echo "Result: No suspended CronJobs, missing recent success after a schedule, or failed latest CronJob-owned Jobs detected."
else
  echo "Result: ${issue_count} CronJob health issue(s). See RunWhen issues and ${OUTPUT_FILE}."
fi
echo "Wrote ${OUTPUT_FILE} (${issue_count} issue(s))."
