#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Reads classified_events.json
# Flags: non-allowlisted mutations; optional maintenance window (UTC hours)
# Writes flag_manual_issues.json
# Env:
#   MAINTENANCE_START_HOUR_UTC, MAINTENANCE_END_HOUR_UTC (optional, 0-23)
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"

OUTPUT_ISSUES="flag_manual_issues.json"
MAINTENANCE_START_HOUR_UTC="${MAINTENANCE_START_HOUR_UTC:-}"
MAINTENANCE_END_HOUR_UTC="${MAINTENANCE_END_HOUR_UTC:-}"
CICD_APP_IDS="${CICD_APP_IDS:-}"
CICD_OBJECT_IDS="${CICD_OBJECT_IDS:-}"

issues_json='[]'

if [[ ! -f classified_events.json ]]; then
  echo "[]" > "$OUTPUT_ISSUES"
  echo "No classified_events.json; run classification task first."
  exit 0
fi

classified=$(cat classified_events.json)

ms="$MAINTENANCE_START_HOUR_UTC"
me="$MAINTENANCE_END_HOUR_UTC"

allowlist_configured=0
[[ -n "${CICD_APP_IDS}${CICD_OBJECT_IDS}" ]] && allowlist_configured=1

flagged=$(echo "$classified" | jq \
  --argjson allow "$allowlist_configured" \
  --arg ms "$ms" \
  --arg me "$me" \
  '
  def hour_utc(ts):
    (ts | split("T")[1] | split(":")[0] | tonumber);
  def in_window(h):
    if ($ms == "" or $me == "") then true
    else
      ($ms | tonumber) as $s | ($me | tonumber) as $e |
      if $s <= $e then (h >= $s and h < $e) else (h >= $s or h < $e) end
    end;
  [.[] | . as $e |
    (hour_utc($e.eventTimestamp)) as $h |
    (in_window($h) | not) as $outside |
    (($allow == 1) and ($e.classification == "manual_suspect")) as $fa |
    {
      event: $e,
      flag_allowlist: $fa,
      flag_window: (($ms != "" and $me != "") and $outside)
    }
  | select(.flag_allowlist or .flag_window)]
')

count=$(echo "$flagged" | jq 'length')

if [[ "$count" -gt 0 ]]; then
  details=$(echo "$flagged" | jq -c '.')
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Manual or Out-of-Band Network Security Changes Detected" \
    --arg d "$details" \
    --arg s "4" \
    --arg n "Investigate flagged events; confirm change tickets; tighten RBAC or pipeline allowlists" \
    '. += [{"title": $t, "details": $d, "severity": ($s | tonumber), "next_steps": $n}]')
fi

echo "$issues_json" > "$OUTPUT_ISSUES"
echo "Flagging complete: $count flagged event bundle(s)."
