#!/usr/bin/env bash
# Compare sampled WAF/security-event volumes against operator thresholds and emit Robot JSON issues.
set -euo pipefail
set -x

PRIMARY="${CLOUDFLARE_WAF_PRIMARY_JSON:-cloudflare_waf_primary_normalized.json}"
PRIOR="${CLOUDFLARE_WAF_PRIOR_JSON:-cloudflare_waf_prior_normalized.json}"
RULE_AGG="${CLOUDFLARE_WAF_RULE_AGG_JSON:-cloudflare_waf_by_rule.json}"
SOURCE_AGG="${CLOUDFLARE_WAF_SOURCE_AGG_JSON:-cloudflare_waf_by_source.json}"
PATH_AGG="${CLOUDFLARE_WAF_PATH_AGG_JSON:-cloudflare_waf_by_path.json}"

TOTAL_THR="${WAF_TOTAL_EVENTS_ISSUE_THRESHOLD:-500}"
ENTITY_THR="${WAF_TOP_ENTITY_ISSUE_THRESHOLD:-100}"
SPIKE_RATIO="${WAF_SPIKE_RATIO_THRESHOLD:-0}"

OUT_ISSUES="${CLOUDFLARE_WAF_THRESHOLD_ISSUES:-cloudflare_waf_threshold_issues.json}"

issues_json='[]'

append_issue() {
  local title="$1" details="$2" severity="$3" next="$4"
  issues_json=$(echo "$issues_json" | jq \
    --arg t "$title" \
    --arg d "$details" \
    --arg ns "$next" \
    --argjson sev "$severity" \
    '. += [{"title": $t, "details": $d, "severity": $sev, "next_steps": $ns}]')
}

if [[ ! -f "${PRIMARY}" ]]; then
  jq -n --arg msg "missing ${PRIMARY}" '[{title:"Missing primary WAF dataset", details:$msg, severity:4, next_steps:"Run Fetch Firewall and WAF Events before thresholds evaluation."}]' >"${OUT_ISSUES}"
  exit 0
fi

primary_total=$(jq '.events | length' "${PRIMARY}")
prior_total=0
if [[ -f "${PRIOR}" ]]; then
  prior_total=$(jq 'if (.events | type == "array") then (.events | length) else 0 end' "${PRIOR}")
fi

if [[ "${primary_total}" -gt "${TOTAL_THR}" ]]; then
  append_issue \
    "WAF sampled-event volume exceeds total threshold for zone window" \
    "Sampled firewall/WAF rows in primary window: ${primary_total} (threshold ${TOTAL_THR}). Dataset uses adaptive sampling; interpret spikes alongside dashboard Firewall Analytics." \
    "3" \
    "Investigate Security Events for spikes; tune Managed Rules / Rate Limits / Bot Fight Mode as appropriate; consider enabling Logpush for definitive counts."
fi

compare_entities() {
  local label="$1" file="$2" jqexpr="$3"
  [[ -f "$file" ]] || return 0
  local max_ent max_rule_json detail severity_title

  max_ent=$(jq -r "${jqexpr}" "$file" || echo "0")
  max_ent=$((max_ent + 0))
  if [[ "${max_ent}" -gt "${ENTITY_THR}" ]]; then
    top_row="$(jq -c '.[0]' "$file" 2>/dev/null || echo {})"
    append_issue \
      "High-volume ${label} bucket exceeds top-entity threshold" \
      "Maximum sampled bucket count=${max_ent} (threshold ${ENTITY_THR}). Example bucket JSON: ${top_row}" \
      "3" \
      "Review the offending IPs/rules/paths in Firewall Analytics; add granular bypass rules only after validating traffic legitimacy."
  fi
}

if [[ -f "${RULE_AGG}" ]]; then
  compare_entities "rule/action/source" "${RULE_AGG}" '[.[].sample_count] | max // 0'
fi

if [[ -f "${SOURCE_AGG}" ]]; then
  ip_max=$(jq '[.top_ips[]?.sample_count] | max // 0' "${SOURCE_AGG}")
  ip_max=$((ip_max + 0))
  if [[ "${ip_max}" -gt "${ENTITY_THR}" ]]; then
    row="$(jq -c '.top_ips[0]' "${SOURCE_AGG}" 2>/dev/null || echo {})"
    append_issue \
      "Concentrated WAF activity from a single client IP" \
      "Top IP sampled-count=${ip_max} (threshold ${ENTITY_THR}). Row=${row}" \
      "3" \
      "Validate whether IP belongs to scanners/CDNs/partners; blocklist cautiously and correlate with origin logs."
  fi
fi

if [[ -f "${PATH_AGG}" ]]; then
  path_max=$(jq '[.top_paths[]?.sample_count] | max // 0' "${PATH_AGG}")
  path_max=$((path_max + 0))
  if [[ "${path_max}" -gt "${ENTITY_THR}" ]]; then
    row="$(jq -c '.top_paths[0]' "${PATH_AGG}" 2>/dev/null || echo {})"
    append_issue \
      "High-volume hostname/path bucket exceeds top-entity threshold" \
      "Maximum sampled host/path bucket count=${path_max} (threshold ${ENTITY_THR}). Example=${row}" \
      "3" \
      "Inspect offending URLs in Firewall Analytics and tune managed/custom rules without weakening protections broadly."
  fi
fi

if awk -v thr="${SPIKE_RATIO:-0}" 'BEGIN { exit !(thr > 0) }'; then
  if [[ "${prior_total}" -gt 0 ]]; then
    if awk -v a="$primary_total" -v b="$prior_total" -v t="$SPIKE_RATIO" 'BEGIN { exit !((b > 0) && ((a / b) >= t)) }'; then
      ratio_human="$(awk -v a="$primary_total" -v b="$prior_total" 'BEGIN { printf "%.2f", (b > 0 ? a / b : 0) }')"
      append_issue \
        "Firewall sampled-volume spike versus prior window" \
        "Primary sampled hits=${primary_total}, prior sampled hits=${prior_total}; ratio≈${ratio_human} with spike threshold=${SPIKE_RATIO}." \
        "4" \
        "Treat as potential coordinated attack or noisy rule deployment — drill into Security Events timeline and recent rule publishes."
    fi
  elif [[ "${prior_total}" -eq 0 && "${primary_total}" -gt "${ENTITY_THR}" ]]; then
    append_issue \
      "Firewall activity emergence versus quiet baseline window" \
      "Prior window sampled hits were zero while primary sampled hits=${primary_total}; spike ratio gate (${SPIKE_RATIO}) flagged emergence." \
      "3" \
      "Confirm baseline window was not truncated by pagination limits; inspect spikes directly in Cloudflare dashboard Security Analytics."
  fi
fi

echo "$issues_json" >"${OUT_ISSUES}"
echo "[+] Threshold evaluation wrote $(jq length "${OUT_ISSUES}") issue(s) → ${OUT_ISSUES}"
