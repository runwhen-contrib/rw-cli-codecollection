#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Raises issues for non-allowlisted mutations and (optionally) changes outside
# MAINTENANCE_START_HOUR_UTC..MAINTENANCE_END_HOUR_UTC (UTC). Window is [start,end)
# when start < end; otherwise wraps past midnight.
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OUTPUT_ISSUES="flag_issues.json"
issues_json='[]'

merge_raw() {
  local nsg="[]"
  local fw="[]"
  [[ -f nsg_writes_raw.json ]] && nsg=$(cat nsg_writes_raw.json)
  [[ -f firewall_writes_raw.json ]] && fw=$(cat firewall_writes_raw.json)
  echo "$nsg" "$fw" | jq -s 'add'
}

classify_merged() {
  local merged_json="$1"
  echo "$merged_json" | jq -c \
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
      $e + {classification: $tag}
    ]
  '
}

merged=$(merge_raw)

if [[ -f classified_events.json ]] && [[ $(jq 'length' classified_events.json 2>/dev/null || echo 0) -gt 0 ]]; then
  classified=$(cat classified_events.json)
else
  classified=$(classify_merged "$merged")
fi

if [[ -n "${CICD_APP_IDS:-}" || -n "${CICD_OBJECT_IDS:-}" ]]; then
  bad_count=$(echo "$classified" | jq '[.[] | select(.classification == "manual_or_unknown")] | length')
  if [[ "$bad_count" -gt 0 ]]; then
    sample=$(echo "$classified" | jq '[.[] | select(.classification == "manual_or_unknown")] | .[0:8]')
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Non-allowlisted identity performed network security mutations" \
      --arg details "$(echo "$sample" | jq -c .)" \
      --argjson severity 4 \
      --arg next_steps "Investigate caller; revoke access if unauthorized or register the identity in CICD_APP_IDS / CICD_OBJECT_IDS" \
      '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
  fi
fi

if [[ -n "${MAINTENANCE_START_HOUR_UTC:-}" && -n "${MAINTENANCE_END_HOUR_UTC:-}" ]]; then
  ms="${MAINTENANCE_START_HOUR_UTC}"
  me="${MAINTENANCE_END_HOUR_UTC}"
  outside=$(echo "$merged" | jq \
    --argjson ms "$ms" \
    --argjson me "$me" \
    '
    [.[] | select(.eventTimestamp != null) |
      (.eventTimestamp | if test("T") then (split("T")[1] | split(":")[0] | tonumber) else 12 end) as $h |
      (if $ms < $me then (($h >= $ms) and ($h < $me))
       else (($h >= $ms) or ($h < $me)) end) as $inside |
      select($inside | not)
    ]')
  oc=$(echo "$outside" | jq 'length')
  if [[ "$oc" -gt 0 ]]; then
    samp=$(echo "$outside" | jq '.[0:8]')
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Network security mutations outside configured maintenance window (UTC)" \
      --arg details "$(echo "$samp" | jq -c .)" \
      --argjson severity 3 \
      --arg next_steps "Align changes with the maintenance window or adjust MAINTENANCE_START_HOUR_UTC / MAINTENANCE_END_HOUR_UTC" \
      '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
  fi
fi

echo "$issues_json" > "$OUTPUT_ISSUES"
echo "Flag script completed"
exit 0
