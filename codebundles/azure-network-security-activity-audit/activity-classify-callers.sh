#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Reads nsg_activity_events.json + firewall_activity_events.json
# Compares caller identity to CICD_APP_IDS and CICD_OBJECT_IDS
# Writes classified_events.json and classify_issues.json
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"

OUTPUT_CLASSIFIED="classified_events.json"
OUTPUT_ISSUES="classify_issues.json"
CICD_APP_IDS="${CICD_APP_IDS:-}"
CICD_OBJECT_IDS="${CICD_OBJECT_IDS:-}"

issues_json='[]'

nsg_raw=$(cat nsg_activity_events.json 2>/dev/null || echo "[]")
fw_raw=$(cat firewall_activity_events.json 2>/dev/null || echo "[]")

app_json=$(echo "$CICD_APP_IDS" | jq -R 'split(",") | map(ascii_downcase | gsub("^ +| +$";"")) | map(select(length>0))')
oid_json=$(echo "$CICD_OBJECT_IDS" | jq -R 'split(",") | map(ascii_downcase | gsub("^ +| +$";"")) | map(select(length>0))')

classified=$(jq -n --argjson apps "$app_json" --argjson oids "$oid_json" \
  --argjson nsg "$nsg_raw" --argjson fw "$fw_raw" '
  def norm: ascii_downcase | gsub("^ +| +$";"");
  def claim_oid(e):
    ((e.claims // {}) | (.["http://schemas.microsoft.com/identity/claims/objectidentifier"] // .oid // .["objectid"] // "") | tostring);
  def claim_app(e):
    ((e.claims // {}) | (.appid // .["http://schemas.microsoft.com/identity/claims/appid"] // "") | tostring);
  def classify(e):
    (claim_app(e) | norm) as $app |
    (claim_oid(e) | norm) as $oid |
    if ($app | length) > 0 and ($apps | index($app)) != null then "automated"
    elif ($oid | length) > 0 and ($oids | index($oid)) != null then "automated"
    elif ($app | length) == 0 and ($oid | length) == 0 then "unknown"
    else "manual_suspect"
    end;
  ($nsg + $fw) | map(. + {
    classification: classify(.),
    appId: claim_app(.),
    objectId: claim_oid(.)
  })
')

echo "$classified" > "$OUTPUT_CLASSIFIED"

manual_count=$(echo "$classified" | jq '[.[] | select(.classification == "manual_suspect")] | length')
unknown_count=$(echo "$classified" | jq '[.[] | select(.classification == "unknown")] | length')

if [[ "$manual_count" -gt 0 ]]; then
  sample=$(echo "$classified" | jq -c '[.[] | select(.classification == "manual_suspect")] | .[0:5]')
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Non-Allowlisted Actors on NSG or Firewall Mutations" \
    --arg d "Found $manual_count event(s) with callers not matching CICD_APP_IDS or CICD_OBJECT_IDS. Sample: $sample" \
    --arg s "3" \
    --arg n "Review these events; add pipeline app IDs or managed identity object IDs to allowlists if legitimate" \
    '. += [{"title": $t, "details": $d, "severity": ($s | tonumber), "next_steps": $n}]')
fi

if [[ "$unknown_count" -gt 0 ]] && [[ -n "${CICD_APP_IDS}${CICD_OBJECT_IDS}" ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Unknown Caller Identity on Some Mutations" \
    --arg d "$unknown_count event(s) lacked appId/objectId claims (often pipeline noise). Cross-check in Azure Portal activity log." \
    --arg s "3" \
    --arg n "Map service principals to CICD_APP_IDS / CICD_OBJECT_IDS; correlate correlationId in Portal" \
    '. += [{"title": $t, "details": $d, "severity": ($s | tonumber), "next_steps": $n}]')
fi

if [[ -z "${CICD_APP_IDS:-}" ]] && [[ -z "${CICD_OBJECT_IDS:-}" ]] && [[ "$(echo "$classified" | jq 'length')" -gt 0 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg t "CI/CD Allowlist Not Configured" \
    --arg d "CICD_APP_IDS and CICD_OBJECT_IDS are empty; classification defaults to manual_suspect/unknown. Configure allowlists for governance signals." \
    --arg s "2" \
    --arg n "Set CICD_APP_IDS (app client IDs) and CICD_OBJECT_IDS (object IDs for identities) in workspace config" \
    '. += [{"title": $t, "details": $d, "severity": ($s | tonumber), "next_steps": $n}]')
fi

echo "$issues_json" > "$OUTPUT_ISSUES"
echo "Classification complete. $OUTPUT_CLASSIFIED written."
