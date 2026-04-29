#!/usr/bin/env bash
# Merge the 4xx / 5xx / other aggregate JSONs into a consolidated summary,
# apply MIN_REQUEST_COUNT_THRESHOLD for noise reduction, and emit a single
# markdown report + a high-signal issue list for the runbook.
#
# Reads:
#   $VERCEL_ARTIFACT_DIR/vercel_aggregate_4xx.json
#   $VERCEL_ARTIFACT_DIR/vercel_aggregate_5xx.json
#   $VERCEL_ARTIFACT_DIR/vercel_aggregate_other.json
#   $VERCEL_ARTIFACT_DIR/vercel_request_log_rows.json (for window context)
# Writes:
#   $VERCEL_ARTIFACT_DIR/vercel_http_error_summary.json
#   $VERCEL_ARTIFACT_DIR/vercel_http_error_report_issues.json
#
# stdout is the markdown report block.

set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=vercel-helpers.sh
source "${SCRIPT_DIR}/vercel-helpers.sh"

vercel_artifact_prepare
ARTIFACT_DIR="$(vercel_artifact_dir)"
ROWS_FILE="${ARTIFACT_DIR}/vercel_request_log_rows.json"
F_4XX="${ARTIFACT_DIR}/vercel_aggregate_4xx.json"
F_5XX="${ARTIFACT_DIR}/vercel_aggregate_5xx.json"
F_OTHER="${ARTIFACT_DIR}/vercel_aggregate_other.json"
SUMMARY_FILE="${ARTIFACT_DIR}/vercel_http_error_summary.json"
ISSUES_FILE="${ARTIFACT_DIR}/vercel_http_error_report_issues.json"

THR="${MIN_REQUEST_COUNT_THRESHOLD:-5}"

echo '{}' >"$SUMMARY_FILE"
echo '[]' >"$ISSUES_FILE"

echo "## Vercel HTTP error summary"
echo
echo "- **Min request count threshold:** ${THR} (counts at or above this are highlighted)"

# Load each bucket file (default to []).
LOAD_4XX="$( [[ -s "$F_4XX" ]] && cat "$F_4XX" || echo '[]' )"
LOAD_5XX="$( [[ -s "$F_5XX" ]] && cat "$F_5XX" || echo '[]' )"
LOAD_OTHER="$( [[ -s "$F_OTHER" ]] && cat "$F_OTHER" || echo '[]' )"

# Merge and produce a totals + top-routes summary.
jq -c -n \
  --argjson c4 "$LOAD_4XX" \
  --argjson c5 "$LOAD_5XX" \
  --argjson co "$LOAD_OTHER" \
  '{"4xx": $c4, "5xx": $c5, "other": $co}' \
  | vercel_paths_summary_jq "$THR" >"$SUMMARY_FILE"

T4="$(jq -r '.totals["4xx"] // 0' "$SUMMARY_FILE")"
T5="$(jq -r '.totals["5xx"] // 0' "$SUMMARY_FILE")"
TO="$(jq -r '.totals["other"] // 0' "$SUMMARY_FILE")"
TOP_LEN="$(jq '.top | length' "$SUMMARY_FILE")"

echo
echo "### Totals (window-wide)"
echo
echo "| Class | Hits |"
echo "| --- | ---: |"
echo "| 4xx | ${T4} |"
echo "| 5xx | ${T5} |"
echo "| other | ${TO} |"

if [[ "${TOP_LEN:-0}" -gt 0 ]]; then
  echo
  echo "### Top noisy routes (count ≥ ${THR})"
  echo
  jq -c '.top' "$SUMMARY_FILE" | vercel_md_routes_table
else
  echo
  echo "_No route exceeded the count threshold of ${THR}; review the per-bucket aggregations above for low-volume entries._"
fi

# Build runbook issues. Only flag substantial volume; the per-bucket scripts
# already handle the inevitable low-count surfacing.
ISSUES_TMP="$(mktemp)"
echo '[]' >"$ISSUES_TMP"

if [[ "$T5" -gt 0 ]]; then
  TOP_5_PATH="$(jq -r '.top | map(select(.code >= 500 and .code < 600)) | .[0].path // ""' "$SUMMARY_FILE")"
  TOP_5_CODE="$(jq -r '.top | map(select(.code >= 500 and .code < 600)) | .[0].code // 0' "$SUMMARY_FILE")"
  TOP_5_COUNT="$(jq -r '.top | map(select(.code >= 500 and .code < 600)) | .[0].count // 0' "$SUMMARY_FILE")"
  jq -n \
    --arg t "Vercel project saw ${T5} 5xx response(s) in the lookback window" \
    --arg d "Top 5xx route: ${TOP_5_PATH:-(below threshold)} returned ${TOP_5_CODE} ${TOP_5_COUNT} time(s). See vercel_http_error_summary.json." \
    --arg n "Inspect Vercel function logs (vercel logs ${TOP_5_PATH:-/}) and recent deploys; correlate with the Resolve Vercel Deployments In Window task to identify the responsible commit." \
    '[{severity: 2, title: $t, details: $d, next_steps: $n}]' >"$ISSUES_TMP"
fi

# 4xx volume above threshold is informational unless it's auth-class (401/403).
HIGH_4XX_AUTH="$(jq -r '[.top[] | select(.code == 401 or .code == 403) | .count] | add // 0' "$SUMMARY_FILE")"
if [[ "${HIGH_4XX_AUTH:-0}" -ge "$THR" ]]; then
  jq -s '.[0] + [{
    severity: 3,
    title: ("Elevated 401/403 volume (" + ($t | tostring) + " hits) on Vercel project"),
    details: "Sustained authentication/authorization rejections may indicate a token rotation, a misconfigured route, or scraping. See vercel_aggregate_4xx.json for routes.",
    next_steps: "Identify the route from the 4xx aggregation, check WAF / middleware logic, and verify any bots or integrations using stale credentials."
  }]' --argjson t "$HIGH_4XX_AUTH" "$ISSUES_TMP" >"${ISSUES_TMP}.new"
  mv "${ISSUES_TMP}.new" "$ISSUES_TMP"
fi

cp "$ISSUES_TMP" "$ISSUES_FILE"
rm -f "$ISSUES_TMP"
