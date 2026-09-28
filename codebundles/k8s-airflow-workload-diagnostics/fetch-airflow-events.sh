#!/usr/bin/env bash
# Lists recent Warning events in the namespace relevant to Airflow workloads.
set -euo pipefail
set -x

: "${CONTEXT:?}" "${NAMESPACE:?}"

OUTPUT_FILE="${OUTPUT_FILE:-fetch_airflow_events_issues.json}"
KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
LABEL_SEL="${AIRFLOW_LABEL_SELECTOR:-app.kubernetes.io/name=airflow}"
PREFIX="${AIRFLOW_DEPLOYMENT_NAME_PREFIX:-airflow}"
LW="${RW_LOOKBACK_WINDOW:-1h}"

if [[ "$LW" =~ ^([0-9]+)h$ ]]; then SEC=$((BASH_REMATCH[1] * 3600))
elif [[ "$LW" =~ ^([0-9]+)m$ ]]; then SEC=$((BASH_REMATCH[1] * 60))
elif [[ "$LW" =~ ^([0-9]+)s$ ]]; then SEC=$((BASH_REMATCH[1]))
else SEC=3600
fi

CUTOFF=$(date -u -d "@$(( $(date +%s) - SEC ))" +%Y-%m-%dT%H:%M:%SZ)

if ! events_json=$("${KUBECTL}" get events -n "${NAMESPACE}" --context "${CONTEXT}" --field-selector type=Warning -o json 2>/dev/null); then
  echo '[{"title":"Cannot list events","details":"kubectl get events failed","severity":4,"next_steps":"Verify RBAC for events in this namespace."}]' | jq . > "$OUTPUT_FILE"
  exit 0
fi

if ! pods_json=$("${KUBECTL}" get pods -n "${NAMESPACE}" --context "${CONTEXT}" -l "${LABEL_SEL}" -o json 2>/dev/null); then
  pods_json='{"items":[]}'
fi

airflow_names=$(echo "$pods_json" | jq -r '[.items[]?.metadata.name] | join("|")')

if ! workloads_json=$("${KUBECTL}" get deploy,sts,ds -n "${NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null); then
  workloads_json='{"items":[]}'
fi

workload_names=$(echo "$workloads_json" | jq -r --arg p "$PREFIX" \
  '[.items[]? | select(.metadata.name | startswith($p)) | .metadata.name] | unique | join("|")')

issues_json=$(echo "$events_json" | jq \
  --arg ns "$NAMESPACE" \
  --arg airflow "$airflow_names" \
  --arg wl "$workload_names" \
  --arg cutoff "$CUTOFF" '
  def name_matches($n; $pat):
    ($pat != "") and (($pat | split("|")) as $parts | any($parts[]; . != "" and $n == .));
  def ts($o):
    ($o.lastTimestamp // $o.firstTimestamp // "");
  [ .items[]? |
    .involvedObject.name as $n |
    .involvedObject.kind as $k |
    select(ts(.) >= $cutoff) |
    select(
      name_matches($n; $airflow) or name_matches($n; $wl) or
      ($n | test("scheduler|webserver|worker|triggerer|dag|airflow"; "i"))
    ) |
    {
      "title": ("Warning event for " + $k + "/" + $n + " in `" + $ns + "`"),
      "details": (.message // ""),
      "severity": 2,
      "next_steps": "Describe the involved object and check volume mounts, probes, and scheduling."
    }
  ] | unique_by(.title)
')

echo "$issues_json" > "$OUTPUT_FILE"

echo "Warning events (since ${CUTOFF}): $(echo "$issues_json" | jq 'length') issue(s) recorded."
