#!/bin/bash
# Check Patroni replication lag and write a structured report for runbook.robot.

set -uo pipefail

# shellcheck disable=SC1091
source patroni_helpers.sh

REPORT_LINES=()
ISSUES=()
THRESHOLD="${DATABASE_LAG_THRESHOLD:-100}"

add_report() {
  REPORT_LINES+=("$1")
  echo "$1"
}

generate_issue() {
  local title="$1"
  local description="$2"
  jq -n \
    --arg title "$title" \
    --arg description "$description" \
    '{title: $title, description: $description}'
}

POD_NAME=$(resolve_workload_exec_pod | tr -d '[:space:]')
CONTAINER="${DATABASE_CONTAINER:-postgres}"

add_report "=== Patroni Replication Lag Check ==="
add_report "Cluster: $OBJECT_NAME | Namespace: $NAMESPACE | Threshold: ${THRESHOLD} MB"
add_report ""

if [[ -z "$POD_NAME" ]]; then
  add_report "ERROR: Could not resolve a running postgres pod for patronictl."
  ISSUES+=("$(generate_issue \
    "No Patroni exec pod for Postgres Cluster \`$OBJECT_NAME\` in \`$NAMESPACE\`" \
    "Could not resolve a running pod from WORKLOAD_NAME or Spilo StatefulSet helpers.")")
else
  add_report "Exec pod: $POD_NAME (container: $CONTAINER)"
  add_report ""

  PATRONI_TEXT=$(patronictl_list_text "$POD_NAME")
  if [[ -n "$PATRONI_TEXT" ]]; then
    add_report "--- patronictl list ---"
    while IFS= read -r line; do
      add_report "$line"
    done <<< "$PATRONI_TEXT"
    add_report ""
  else
    add_report "WARNING: patronictl list returned no output from pod $POD_NAME."
    ISSUES+=("$(generate_issue \
      "Patroni status unavailable for Postgres Cluster \`$OBJECT_NAME\` in \`$NAMESPACE\`" \
      "patronictl list returned no output from pod \`$POD_NAME\`.")")
  fi

  MEMBERS_JSON=$(patronictl_list_members_json "$POD_NAME" 2>/dev/null || echo "[]")
  if [[ "$MEMBERS_JSON" != "[]" ]] && command -v jq &>/dev/null; then
    while IFS= read -r member; do
      [[ -z "$member" ]] && continue
      lag=$(echo "$member" | jq -r '."Lag in MB" // 0')
      name=$(echo "$member" | jq -r '.Member // "unknown"')
      cluster=$(echo "$member" | jq -r '.Cluster // "unknown"')
      role=$(echo "$member" | jq -r '.Role // "unknown"')
      add_report "Member $name ($role) lag: ${lag} MB"
      if [[ "$lag" =~ ^[0-9.]+$ ]] && awk -v lag="$lag" -v threshold="$THRESHOLD" 'BEGIN { exit !(lag > threshold + 0) }'; then
        ISSUES+=("$(generate_issue \
          "Database member \`$name\` in cluster \`$cluster\` has lag of ${lag} MB in \`$NAMESPACE\`" \
          "Replication lag ${lag} MB exceeds threshold of ${THRESHOLD} MB for member \`$name\` (role: $role).")")
      fi
    done < <(echo "$MEMBERS_JSON" | jq -c '.[]')
  elif [[ -n "$PATRONI_TEXT" ]]; then
    add_report "INFO: Lag values could not be parsed as JSON; see patronictl table above."
  fi
fi

add_report ""
add_report "=== Patroni Lag Check Complete ==="

OUTPUT_FILE="../patroni_lag_report.out"
{
  echo "Patroni Lag Report:"
  for line in "${REPORT_LINES[@]}"; do
    echo "$line"
  done
  echo ""
  echo "Issues:"
  echo "["
  for i in "${!ISSUES[@]}"; do
    if [[ $i -gt 0 ]]; then
      echo ","
    fi
    echo "${ISSUES[$i]}"
  done
  echo "]"
} > "$OUTPUT_FILE"

echo "Patroni lag report written to $OUTPUT_FILE"
