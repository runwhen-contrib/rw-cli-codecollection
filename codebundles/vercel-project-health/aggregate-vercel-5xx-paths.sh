#!/usr/bin/env bash
# Bucket all 5xx (500-599) responses from the shared request-log rows
# (vercel_request_log_rows.json) by code/path/method.
#
# Reads:
#   $VERCEL_ARTIFACT_DIR/vercel_request_log_rows.json
# Writes:
#   $VERCEL_ARTIFACT_DIR/vercel_aggregate_5xx.json
#   $VERCEL_ARTIFACT_DIR/vercel_aggregate_5xx_issues.json
#
# stdout is the markdown report block.

set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=vercel-helpers.sh
source "${SCRIPT_DIR}/vercel-helpers.sh"

vercel_artifact_prepare
ARTIFACT_DIR="$(vercel_artifact_dir)"
ROWS_FILE="${ARTIFACT_DIR}/vercel_request_log_rows.json"
OUT_FILE="${ARTIFACT_DIR}/vercel_aggregate_5xx.json"
ISSUES_FILE="${ARTIFACT_DIR}/vercel_aggregate_5xx_issues.json"

echo '[]' >"$OUT_FILE"
echo '[]' >"$ISSUES_FILE"

echo "## 5xx aggregation (500-599)"
echo
echo "- **Source:** \`${ROWS_FILE}\`"

if [[ ! -s "$ROWS_FILE" ]]; then
  echo
  echo "_No request-log rows file found. Run the collector task first._"
  exit 0
fi

TOTAL_ROWS="$(jq 'length' "$ROWS_FILE" 2>/dev/null || echo 0)"
TOTAL_ROWS="${TOTAL_ROWS:-0}"
echo "- **Input rows:** ${TOTAL_ROWS}"
echo

if [[ "$TOTAL_ROWS" == "0" ]]; then
  echo "_No rows to aggregate — collector returned 0 normalized rows._"
  exit 0
fi

# Read the rows file directly into jq — see aggregate-vercel-4xx-paths.sh
# for the rationale (avoids inherited-stdin hang inside command substitution).
vercel_aggregate_status_bucket 5xx <"$ROWS_FILE" >"$OUT_FILE"

BUCKET_COUNT="$(jq 'length' "$OUT_FILE" 2>/dev/null || echo 0)"
BUCKET_COUNT="${BUCKET_COUNT:-0}"
TOTAL_5XX="$(jq '[.[] | .count] | add // 0' "$OUT_FILE" 2>/dev/null || echo 0)"

echo "- **Distinct (code, path, method) groups:** ${BUCKET_COUNT}"
echo "- **Total 5xx hits:** ${TOTAL_5XX}"
echo
echo "### Top 5xx routes"
echo
jq -c '.[0:25]' "$OUT_FILE" | vercel_md_routes_table

# 5xx are server-side errors and should be flagged distinctly.
if [[ "$TOTAL_5XX" -gt 0 ]]; then
  TOP_PATH="$(jq -r '.[0].path // "-"' "$OUT_FILE" 2>/dev/null)"
  TOP_CODE="$(jq -r '.[0].code // 0' "$OUT_FILE" 2>/dev/null)"
  TOP_COUNT="$(jq -r '.[0].count // 0' "$OUT_FILE" 2>/dev/null)"
  ISSUE_TITLE="${TOTAL_5XX} 5xx response(s) observed in Vercel request logs"
  ISSUE_DETAILS="Top route: \`${TOP_PATH}\` returned ${TOP_CODE} ${TOP_COUNT} time(s) in this window. See vercel_aggregate_5xx.json for the full breakdown."
  ISSUE_NEXT_STEPS="Inspect Vercel function logs and recent commits to that route; check the Build Consolidated HTTP Error Summary report for severity ranking."
  jq -n --arg t "$ISSUE_TITLE" --arg d "$ISSUE_DETAILS" --arg n "$ISSUE_NEXT_STEPS" \
    '[{severity: 2, title: $t, details: $d, next_steps: $n}]' >"$ISSUES_FILE"
fi
