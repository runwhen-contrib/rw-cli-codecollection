#!/usr/bin/env bash
# Break down sampled firewall activity by hostname (when present) and URL path.
set -euo pipefail
set -x

PRIMARY="${CLOUDFLARE_WAF_PRIMARY_JSON:-cloudflare_waf_primary_normalized.json}"
TOP_N="${WAF_REPORT_TOP_N:-15}"
OUT_JSON="${CLOUDFLARE_WAF_PATH_AGG_JSON:-cloudflare_waf_by_path.json}"
ISSUES_JSON="${CLOUDFLARE_WAF_PATH_ISSUES:-cloudflare_waf_path_issues.json}"

echo '[]' >"${ISSUES_JSON}"

if [[ ! -f "${PRIMARY}" ]]; then
  jq -n --arg p "${PRIMARY}" '{error:"missing_primary", path:$p}' >"${OUT_JSON}"
  exit 0
fi

jq --argjson top "${TOP_N}" '
  (.events // []) as $ev
  | {
      top_paths: (
        $ev
        | map(. + {host: (.clientRequestHTTPHostName // ""), path: (.clientRequestPath // "")})
        | group_by(.host + "\u001f" + .path)
        | map({
            host: (.[0].host),
            path: (.[0].path),
            sample_count: length
          })
        | sort_by(-.sample_count)
        | .[0:$top]
      ),
      top_hosts: (
        $ev
        | map(.clientRequestHTTPHostName // "")
        | map(select(length > 0))
        | group_by(.)
        | map({host: .[0], sample_count: length})
        | sort_by(-.sample_count)
        | .[0:$top]
      )
    }
' "${PRIMARY}" >"${OUT_JSON}"

echo "[+] Host/path aggregation → ${OUT_JSON}"
