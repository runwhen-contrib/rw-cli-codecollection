#!/usr/bin/env bash
# Group sampled firewall events by rule id, action, and source service.
set -euo pipefail
set -x

PRIMARY="${CLOUDFLARE_WAF_PRIMARY_JSON:-cloudflare_waf_primary_normalized.json}"
OUT_JSON="${CLOUDFLARE_WAF_RULE_AGG_JSON:-cloudflare_waf_by_rule.json}"
ISSUES_JSON="${CLOUDFLARE_WAF_RULE_ISSUES:-cloudflare_waf_rule_aggregate_issues.json}"

echo '[]' >"${ISSUES_JSON}"

if [[ ! -f "${PRIMARY}" ]]; then
  jq -n --arg p "${PRIMARY}" '{error:"missing_primary", path:$p}' >"${OUT_JSON}"
  exit 0
fi

jq '
  (.events // []) 
  | map(. + {rule_key: (.ruleId // .rule_id // "unknown")})
  | group_by(.rule_key + "|" + (.source // "?") + "|" + (.action // "?"))
  | map({
      rule_id: (.[0].rule_key),
      source: (.[0].source // null),
      action: (.[0].action // null),
      sample_count: length
    })
  | sort_by(-.sample_count)
' "${PRIMARY}" >"${OUT_JSON}"

echo "[+] Rule/action/service aggregation → ${OUT_JSON}"
