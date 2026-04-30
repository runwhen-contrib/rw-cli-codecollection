#!/usr/bin/env bash
# Bucket additional unhealthy HTTP codes (UNHEALTHY_HTTP_CODES env, default
# "408,429") from the shared request-log rows by code/path/method.
#
# Reads:
#   $VERCEL_ARTIFACT_DIR/vercel_request_log_rows.json
# Writes:
#   $VERCEL_ARTIFACT_DIR/vercel_aggregate_other.json
#   $VERCEL_ARTIFACT_DIR/vercel_aggregate_other_issues.json
#
# stdout is the markdown report block.

set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=vercel-helpers.sh
source "${SCRIPT_DIR}/vercel-helpers.sh"

vercel_artifact_prepare
ARTIFACT_DIR="$(vercel_artifact_dir)"
ROWS_FILE="${ARTIFACT_DIR}/vercel_request_log_rows.json"
OUT_FILE="${ARTIFACT_DIR}/vercel_aggregate_other.json"
ISSUES_FILE="${ARTIFACT_DIR}/vercel_aggregate_other_issues.json"
EXTRA_CODES="${UNHEALTHY_HTTP_CODES:-408,429}"

echo '[]' >"$OUT_FILE"
echo '[]' >"$ISSUES_FILE"

echo "## Other unhealthy code aggregation"
echo
echo "- **Source:** \`${ROWS_FILE}\`"
echo "- **Tracked codes:** \`${EXTRA_CODES}\`"

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
vercel_aggregate_status_bucket other "$EXTRA_CODES" <"$ROWS_FILE" >"$OUT_FILE"

BUCKET_COUNT="$(jq 'length' "$OUT_FILE" 2>/dev/null || echo 0)"
BUCKET_COUNT="${BUCKET_COUNT:-0}"
TOTAL_OTHER="$(jq '[.[] | .count] | add // 0' "$OUT_FILE" 2>/dev/null || echo 0)"

echo "- **Distinct (code, path, method) groups:** ${BUCKET_COUNT}"
echo "- **Total hits:** ${TOTAL_OTHER}"
echo
echo "### Top routes"
echo
jq -c '.[0:25]' "$OUT_FILE" | vercel_md_routes_table
