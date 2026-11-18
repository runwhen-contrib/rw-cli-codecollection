#!/usr/bin/env bash
# Emit a consolidated textual summary referencing fetched firewall analytics artifacts.
set -euo pipefail
set -x

PRIMARY="${CLOUDFLARE_WAF_PRIMARY_JSON:-cloudflare_waf_primary_normalized.json}"
RULE_AGG="${CLOUDFLARE_WAF_RULE_AGG_JSON:-cloudflare_waf_by_rule.json}"
SOURCE_AGG="${CLOUDFLARE_WAF_SOURCE_AGG_JSON:-cloudflare_waf_by_source.json}"
PATH_AGG="${CLOUDFLARE_WAF_PATH_AGG_JSON:-cloudflare_waf_by_path.json}"

ISSUES_JSON="${CLOUDFLARE_WAF_REPORT_ISSUES:-cloudflare_waf_report_issues.json}"
echo '[]' >"${ISSUES_JSON}"

{
  echo "=== Cloudflare Zone WAF & Security Events Summary ==="
  echo ""

  if [[ -f "${PRIMARY}" ]]; then
    jq -r '
      "## Zone\n"
      + "- Zone tag: " + (.meta.zone_tag // "?") + "\n"
      + "- Primary window: " + (.meta.window.start // "?") + " → " + (.meta.window.end // "?") + "\n"
      + "- Sampled rows fetched (primary): " + ((.events | length) | tostring) + "\n"
      + "- Dataset note: " + (.meta.dataset_note // "") + "\n"
    ' "${PRIMARY}"
  else
    echo "(Primary normalized JSON missing — did fetch succeed?)"
  fi

  echo ""
  echo "## Top rule/action/source buckets (sampled counts)"
  if [[ -f "${RULE_AGG}" ]]; then
    jq -r '.[0:10][] | "- rule=\(.rule_id // "?") source=\(.source // "?") action=\(.action // "?") count=\(.sample_count)"' "${RULE_AGG}" 2>/dev/null || echo "(unable to parse rule aggregation)"
  else
    echo "(aggregate-waf-by-rule output missing)"
  fi

  echo ""
  echo "## Top IPs / countries (sampled counts)"
  if [[ -f "${SOURCE_AGG}" ]]; then
    echo "- IPs:"
    jq -r '.top_ips[:10][]? | "  * ip=\(.client_ip) count=\(.sample_count)"' "${SOURCE_AGG}" 2>/dev/null || true
    echo "- Countries:"
    jq -r '.top_countries[:10][]? | "  * country=\(.country) count=\(.sample_count)"' "${SOURCE_AGG}" 2>/dev/null || true
  else
    echo "(correlate-waf-by-source output missing)"
  fi

  echo ""
  echo "## Top hosts/paths (sampled counts)"
  if [[ -f "${PATH_AGG}" ]]; then
    jq -r '.top_paths[:10][]? | "- host=\(.host // "") path=\(.path // "") count=\(.sample_count)"' "${PATH_AGG}" 2>/dev/null || echo "(unable to parse path aggregation)"
  else
    echo "(aggregate-waf-by-path output missing)"
  fi

  echo ""
  echo "## References"
  echo "- GraphQL Analytics overview: https://developers.cloudflare.com/analytics/graphql-api/"
  echo "- Firewall Events tutorial: https://developers.cloudflare.com/analytics/graphql-api/tutorials/querying-firewall-events/"
  echo "- Sampling behavior: https://developers.cloudflare.com/analytics/graphql-api/sampling/"
} 

echo ""
echo "[+] Summary rendered (issues JSON intentionally empty at ${ISSUES_JSON})"
