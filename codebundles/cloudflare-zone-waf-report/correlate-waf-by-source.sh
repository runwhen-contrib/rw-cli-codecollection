#!/usr/bin/env bash
# Correlate sampled events by client IP, ASN, and country with top-N tables.
set -euo pipefail
set -x

PRIMARY="${CLOUDFLARE_WAF_PRIMARY_JSON:-cloudflare_waf_primary_normalized.json}"
TOP_N="${WAF_REPORT_TOP_N:-15}"
OUT_JSON="${CLOUDFLARE_WAF_SOURCE_AGG_JSON:-cloudflare_waf_by_source.json}"
ISSUES_JSON="${CLOUDFLARE_WAF_SOURCE_ISSUES:-cloudflare_waf_source_issues.json}"

echo '[]' >"${ISSUES_JSON}"

if [[ ! -f "${PRIMARY}" ]]; then
  jq -n --arg p "${PRIMARY}" '{error:"missing_primary", path:$p}' >"${OUT_JSON}"
  exit 0
fi

jq --argjson top "${TOP_N}" '
  (.events // []) as $ev
  | {
      top_ips: (
        $ev
        | group_by(.clientIP // "unknown")
        | map({client_ip: (.[0].clientIP // "unknown"), sample_count: length})
        | sort_by(-.sample_count)
        | .[0:$top]
      ),
      top_asns: (
        $ev
        | group_by(.clientAsn // "unknown")
        | map({asn: (.[0].clientAsn // "unknown"), sample_count: length})
        | sort_by(-.sample_count)
        | .[0:$top]
      ),
      top_countries: (
        $ev
        | group_by(.clientCountryName // "unknown")
        | map({country: (.[0].clientCountryName // "unknown"), sample_count: length})
        | sort_by(-.sample_count)
        | .[0:$top]
      ),
      distinct_ip_estimate: ($ev | map(.clientIP // "") | unique | length)
    }
' "${PRIMARY}" >"${OUT_JSON}"

echo "[+] Source ASN/IP/country aggregation → ${OUT_JSON}"
