#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Classifies mutation events against CICD_APP_IDS and CICD_OBJECT_IDS (comma lists).
# Reads nsg_writes_raw.json and firewall_writes_raw.json from the bundle working directory.
# Writes classify_issues.json and classified_events.json
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OUTPUT_ISSUES="classify_issues.json"
issues_json='[]'

merge_raw() {
  local nsg="[]"
  local fw="[]"
  [[ -f nsg_writes_raw.json ]] && nsg=$(cat nsg_writes_raw.json)
  [[ -f firewall_writes_raw.json ]] && fw=$(cat firewall_writes_raw.json)
  echo "$nsg" "$fw" | jq -s 'add'
}

merged=$(merge_raw)
total=$(echo "$merged" | jq 'length')

if [[ -z "${CICD_APP_IDS:-}" && -z "${CICD_OBJECT_IDS:-}" ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Caller allowlist not configured" \
    --arg details "Set CICD_APP_IDS and/or CICD_OBJECT_IDS to classify automation versus manual changes. Events in window: ${total}" \
    --argjson severity 1 \
    --arg next_steps "Populate allowlists with known pipeline app IDs and managed identity object IDs" \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_ISSUES"
  echo "[]" > "classified_events.json"
  echo "Classification skipped (no allowlists); merged events: ${total}"
  exit 0
fi

classified=$(echo "$merged" | jq -c \
  --arg apps "${CICD_APP_IDS:-}" \
  --arg oids "${CICD_OBJECT_IDS:-}" \
  '
  def split_list($s): ($s | split(",") | map(gsub("^\\s+";"") | gsub("\\s+$";"")) | map(select(length > 0)));
  def appid($c): ($c["appid"] // $c["http://schemas.microsoft.com/identity/claims/applicationid"] // "") | tostring;
  def oid($c): ($c["http://schemas.microsoft.com/identity/claims/objectidentifier"] // $c["oid"] // "") | tostring;
  (split_list($apps)) as $appList |
  (split_list($oids)) as $oidList |
  [.[] | . as $e | ($e.claims // {}) as $c |
    (appid($c)) as $ap |
    (oid($c)) as $ob |
    ($e.caller // "") as $caller |
    (
      if ($ap != "" and ($appList | index($ap) != null)) then "automated"
      elif ($ob != "" and ($oidList | index($ob) != null)) then "automated"
      elif ($caller != "" and (($appList | index($caller) != null) or ($oidList | index($caller) != null))) then "automated"
      else "manual_or_unknown"
      end
    ) as $tag |
    $e + {classification: $tag, resolvedAppId: $ap, resolvedObjectId: $ob}
  ]
')

echo "$classified" | jq . > "classified_events.json"

manual_count=$(echo "$classified" | jq '[.[] | select(.classification == "manual_or_unknown")] | length')
if [[ "$manual_count" -gt 0 ]]; then
  sample=$(echo "$classified" | jq '[.[] | select(.classification == "manual_or_unknown")] | .[0:10]')
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Mutations classified as manual or unknown caller" \
    --arg details "$(echo "$sample" | jq -c .)" \
    --argjson severity 3 \
    --arg next_steps "Review events; add missing app or object IDs to allowlists if legitimate automation" \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
fi

echo "$issues_json" > "$OUTPUT_ISSUES"
echo "Classified ${total} events; manual_or_unknown: ${manual_count}"
exit 0
