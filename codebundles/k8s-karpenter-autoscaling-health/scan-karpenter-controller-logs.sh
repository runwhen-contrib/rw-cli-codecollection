#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Scans Karpenter controller pod logs for error/warn patterns.
# Required: CONTEXT, KARPENTER_NAMESPACE (default karpenter)
# Optional: RW_LOOKBACK_WINDOW (default 30m), KARPENTER_LOG_ERROR_THRESHOLD (default 1)
# Output: karpenter_controller_log_issues.json
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"

OUTPUT_FILE="${OUTPUT_FILE:-karpenter_controller_log_issues.json}"
KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
NS="${KARPENTER_NAMESPACE:-karpenter}"
LOOKBACK="${RW_LOOKBACK_WINDOW:-30m}"
THRESHOLD="${KARPENTER_LOG_ERROR_THRESHOLD:-1}"
MAX_TAIL_LINES="${KARPENTER_LOG_MAX_LINES:-500}"
LOG_SNIPPET_FILE="karpenter_controller_log_hits.txt"

if ! command -v jq &>/dev/null; then
  echo '[{"title":"jq Not Available","details":"Install jq.","severity":3,"next_steps":"Install jq."}]' | jq . >"$OUTPUT_FILE"
  exit 0
fi

issues_json='[]'

if ! $KUBECTL get ns "$NS" --context "$CONTEXT" &>/dev/null; then
  echo '[{"title":"Karpenter Namespace Not Found","details":"Set KARPENTER_NAMESPACE.","severity":2,"next_steps":"kubectl get deploy -A | grep -i karpenter"}]' | jq . >"$OUTPUT_FILE"
  exit 0
fi

labels=(
  "app.kubernetes.io/name=karpenter"
  "app=karpenter"
  "karpenter.sh/control-plane=true"
)
selector=""
for l in "${labels[@]}"; do
  if $KUBECTL get pods -n "$NS" --context "$CONTEXT" -l "$l" -o name 2>/dev/null | head -1 | grep -q pod; then
    selector="$l"
    break
  fi
done

if [[ -n "$selector" ]]; then
  mapfile -t pods < <($KUBECTL get pods -n "$NS" --context "$CONTEXT" -l "$selector" -o json 2>/dev/null | jq -r '.items[].metadata.name' | head -5)
else
  mapfile -t pods < <($KUBECTL get pods -n "$NS" --context "$CONTEXT" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | test("karpenter"; "i")) | .metadata.name' | head -5)
fi

if [[ ${#pods[@]} -eq 0 ]]; then
  echo '[{"title":"No Karpenter Controller Pods Found","details":"Could not find controller pods.","severity":3,"next_steps":"Verify installation and labels in namespace."}]' | jq . >"$OUTPUT_FILE"
  exit 0
fi

: >"$LOG_SNIPPET_FILE"
for p in "${pods[@]}"; do
  timeout 90s $KUBECTL logs -n "$NS" "$p" --context "$CONTEXT" --since="$LOOKBACK" --tail="$MAX_TAIL_LINES" --all-containers=true 2>/dev/null >>"$LOG_SNIPPET_FILE" || true
done

PATTERN='ERROR|ERRO|WARN|FATAL|fatal|panic|Insufficient|insufficient|ICE|launch failed|LaunchFailed|UnauthorizedOperation|AccessDenied|InvalidParameter|CreateLaunchTemplate|RunInstances|Subnet|SecurityGroup|AMI|InstanceProfile|NoSuchEntity|ValidationError|webhook|failed to'

matches=0
if [[ -s "$LOG_SNIPPET_FILE" ]]; then
  matches=$(grep -Ei "$PATTERN" "$LOG_SNIPPET_FILE" | wc -l | tr -d ' ' || echo 0)
fi

if [[ "${matches:-0}" -ge "$THRESHOLD" ]]; then
  excerpt=$(grep -Ei "$PATTERN" "$LOG_SNIPPET_FILE" 2>/dev/null | head -40 || true)
  jq -n \
    --arg title "Karpenter controller logs: ${matches} matching lines in \`${NS}\`" \
    --arg details "Lookback: ${LOOKBACK}. Threshold: ${THRESHOLD}. Sample:\n${excerpt}" \
    --arg next "kubectl logs -n ${NS} deploy/karpenter --since=${LOOKBACK} (adjust deployment name). Review AWS IAM, subnets, and security groups." \
    '[{
      "title": $title,
      "details": $details,
      "severity": 3,
      "next_steps": $next
    }]' >"$OUTPUT_FILE"
else
  echo '[]' | jq . >"$OUTPUT_FILE"
fi

echo "Log scan complete; matches=${matches:-0}"
