#!/usr/bin/env bash
# Bucket all 4xx (400-499) responses from the shared request-log rows
# (vercel_request_log_rows.json) by code/path/method.
#
# Reads:
#   $VERCEL_ARTIFACT_DIR/vercel_request_log_rows.json (from collect-vercel-request-logs.sh)
# Writes:
#   $VERCEL_ARTIFACT_DIR/vercel_aggregate_4xx.json
#   $VERCEL_ARTIFACT_DIR/vercel_aggregate_4xx_issues.json
#
# stdout is the markdown report block.

set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=vercel-helpers.sh
source "${SCRIPT_DIR}/vercel-helpers.sh"

vercel_artifact_prepare
ARTIFACT_DIR="$(vercel_artifact_dir)"
ROWS_FILE="${ARTIFACT_DIR}/vercel_request_log_rows.json"
OUT_FILE="${ARTIFACT_DIR}/vercel_aggregate_4xx.json"
ISSUES_FILE="${ARTIFACT_DIR}/vercel_aggregate_4xx_issues.json"

echo '[]' >"$OUT_FILE"
echo '[]' >"$ISSUES_FILE"

echo "## 4xx aggregation (400-499)"
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

# Bucket and group. Read the rows file directly into jq — DO NOT pipe through
# bash variables / command substitution: when this script is launched via
# subprocess.run with parent stdin attached (RW.CLI default), inner jq calls
# inside `$()` block forever waiting for EOF on inherited stdin.
vercel_aggregate_status_bucket 4xx <"$ROWS_FILE" >"$OUT_FILE"

BUCKET_COUNT="$(jq 'length' "$OUT_FILE" 2>/dev/null || echo 0)"
BUCKET_COUNT="${BUCKET_COUNT:-0}"
TOTAL_4XX="$(jq '[.[] | .count] | add // 0' "$OUT_FILE" 2>/dev/null || echo 0)"

echo "- **Distinct (code, path, method) groups:** ${BUCKET_COUNT}"
echo "- **Total 4xx hits:** ${TOTAL_4XX}"
echo
echo "### Top 4xx routes"
echo
jq -c '.[0:25]' "$OUT_FILE" | vercel_md_routes_table
