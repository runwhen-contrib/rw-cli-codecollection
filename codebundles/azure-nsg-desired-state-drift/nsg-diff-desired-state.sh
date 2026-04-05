#!/usr/bin/env bash
# Compare normalized live export vs baseline; emit drift issues.
# Inputs: nsg_live_export.json, nsg_baseline_normalized.json
# Output: nsg_diff_issues.json
set -euo pipefail
set -x

LIVE="${LIVE_EXPORT_FILE:-nsg_live_export.json}"
BASE="${BASELINE_FILE:-nsg_baseline_normalized.json}"
OUT="nsg_diff_issues.json"

issues_json='[]'

if [ ! -f "$LIVE" ] || [ ! -f "$BASE" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Missing normalized JSON for diff" \
    --arg details "Expected $LIVE and $BASE from prior tasks." \
    --argjson severity 4 \
    --arg next_steps "Run export and baseline load tasks successfully before diff." \
    '. += [{ "title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps }]')
  echo "$issues_json" | jq . > "$OUT"
  exit 0
fi

if ! jq -e '.nsgName' "$LIVE" >/dev/null 2>&1; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Live export JSON is invalid" \
    --arg details "File $LIVE does not contain a valid NSG export." \
    --argjson severity 4 \
    --arg next_steps "Fix export task errors and rerun." \
    '. += [{ "title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps }]')
  echo "$issues_json" | jq . > "$OUT"
  exit 0
fi

if ! jq -e '.nsgName' "$BASE" >/dev/null 2>&1; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Baseline JSON is invalid" \
    --arg details "File $BASE does not contain a valid normalized NSG." \
    --argjson severity 3 \
    --arg next_steps "Fix baseline content or path." \
    '. += [{ "title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps }]')
  echo "$issues_json" | jq . > "$OUT"
  exit 0
fi

IGNORE_RULE_PREFIXES="${IGNORE_RULE_PREFIXES:-}"

DIFF_JSON=$(jq -n --slurpfile live "$LIVE" --slurpfile base "$BASE" \
  --arg prefixes "$IGNORE_RULE_PREFIXES" '
  def should_keep($name):
    if $prefixes == "" or $prefixes == null then true
    else
      ($prefixes | split(",") | map(gsub("^ +";"") | gsub(" +$";"")) | map(select(length > 0)))
      as $prefs
      | all($prefs[]; ($name | startswith(.) | not))
    end;
  def norm_set($arr): [ $arr[]? | select(should_keep(.name)) ] | INDEX(.name);
  live[0] as $live | base[0] as $base
  | norm_set($live.securityRules) as $L
  | norm_set($base.securityRules) as $B
  | ($L | keys) as $lk | ($B | keys) as $bk
  | {
      missing_in_live: [ $bk[] | select($L[.] == null) ],
      extra_in_live: [ $lk[] | select($B[.] == null) ],
      changed: [
        [ ($lk + $bk | unique)[] | select($L[.] != null and $B[.] != null)
        | select(($L[.] | tostring) != ($B[.] | tostring)) ]
      ]
    }
')

NSG_NAME=$(jq -r '.nsgName' "$LIVE")

while IFS= read -r name; do
  [ -z "$name" ] && continue
  br=$(jq -c --arg n "$name" '.securityRules[]? | select(.name==$n)' "$BASE")
  details=$(jq -n --argjson b "$br" '{baseline_rule:$b,note:"Rule present in baseline but missing in live Azure NSG"}')
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Drift: rule \`$name\` missing in live NSG \`$NSG_NAME\` (present in baseline)" \
    --arg details "$(echo "$details" | jq -c .)" \
    --argjson severity 3 \
    --arg next_steps "Restore the rule in Azure via your pipeline or update baseline if the deletion was intentional." \
    '. += [{ "title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps }]')
done < <(echo "$DIFF_JSON" | jq -r '.missing_in_live[]?')

while IFS= read -r name; do
  [ -z "$name" ] && continue
  lr=$(jq -c --arg n "$name" '.securityRules[]? | select(.name==$n)' "$LIVE")
  details=$(jq -n --argjson l "$lr" '{live_rule:$l,note:"Rule exists in Azure but not in baseline"}')
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Drift: extra rule \`$name\` on live NSG \`$NSG_NAME\` (not in baseline)" \
    --arg details "$(echo "$details" | jq -c .)" \
    --argjson severity 4 \
    --arg next_steps "Remove unauthorized rule or add an approved baseline entry; reconcile via IaC." \
    '. += [{ "title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps }]')
done < <(echo "$DIFF_JSON" | jq -r '.extra_in_live[]?')

while IFS= read -r name; do
  [ -z "$name" ] && continue
  LIVE_RULE=$(jq -c --arg n "$name" '.securityRules[]? | select(.name==$n)' "$LIVE")
  BASE_RULE=$(jq -c --arg n "$name" '.securityRules[]? | select(.name==$n)' "$BASE")
  details=$(jq -n --argjson l "$LIVE_RULE" --argjson b "$BASE_RULE" '{live:$l,baseline:$b}')
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Drift: rule \`$name\` differs between live and baseline for NSG \`$NSG_NAME\`" \
    --arg details "$(echo "$details" | jq -c .)" \
    --argjson severity 3 \
    --arg next_steps "Align properties with baseline or document an approved baseline update." \
    '. += [{ "title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps }]')
done < <(echo "$DIFF_JSON" | jq -r '.changed[]?')

if [ "${COMPARE_DEFAULT_RULES:-false}" = "true" ]; then
  if ! cmp -s <(jq -c '.defaultSecurityRules' "$LIVE") <(jq -c '.defaultSecurityRules' "$BASE"); then
    details=$(jq -n --argjson l "$(jq -c '.defaultSecurityRules' "$LIVE")" --argjson b "$(jq -c '.defaultSecurityRules' "$BASE")" '{live:$l,baseline:$b}')
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Default security rules differ for NSG \`$NSG_NAME\`" \
      --arg details "$(echo "$details" | jq -c .)" \
      --argjson severity 2 \
      --arg next_steps "Azure default rules are usually stable; verify API skew or template drift." \
      '. += [{ "title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps }]')
  fi
fi

echo "$issues_json" | jq . > "$OUT"
echo "Diff complete; issues written to $OUT"
