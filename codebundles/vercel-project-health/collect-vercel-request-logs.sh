#!/usr/bin/env bash
# Render the Vercel request-logs collection summary. The Robot caller already
# fetched and normalized rows via the `Vercel` Python keyword library and
# dropped them at $VERCEL_REQUEST_LOG_ROWS_PATH (a JSON array of normalized
# rows: {ts, code, path, method, source, domain, level, deployment_id,
# branch, environment, duration_ms, cache, region, error_code}). Robot also
# surfaces issues for missing ownerId / API failures, so this script focuses
# on the markdown report + a small debug summary file.
#
# Outputs to $VERCEL_ARTIFACT_DIR (default `.`):
#   vercel_request_log_rows.json            — already written by Robot (read-only here)
#   vercel_request_log_rows.debug.json      — counts + sampled metadata
#   vercel_request_log_rows_issues.json     — empty (Robot owns API issues)
#
# stdout: a markdown report block embedded into the runbook report.
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=vercel-helpers.sh
source "${SCRIPT_DIR}/vercel-helpers.sh"

vercel_artifact_prepare
ARTIFACT_DIR="$(vercel_artifact_dir)"
ROWS_FILE="${VERCEL_REQUEST_LOG_ROWS_PATH:-${ARTIFACT_DIR}/vercel_request_log_rows.json}"
DEBUG_FILE="${ARTIFACT_DIR}/vercel_request_log_rows.debug.json"
ISSUES_FILE="${ARTIFACT_DIR}/vercel_request_log_rows_issues.json"

ENVIRONMENT_FILTER="${VERCEL_REQUEST_LOGS_ENV:-production}"
MAX_ROWS="${VERCEL_REQUEST_LOGS_MAX_ROWS:-5000}"
MAX_PAGES="${VERCEL_REQUEST_LOGS_MAX_PAGES:-20}"
WIN_START_MS="${VERCEL_WIN_START_MS:-0}"
WIN_END_MS="${VERCEL_WIN_END_MS:-0}"

echo '[]' >"$ISSUES_FILE"
[[ -f "$ROWS_FILE" ]] || echo '[]' >"$ROWS_FILE"
echo '{}' >"$DEBUG_FILE"

echo "## Vercel request logs"
echo
echo "- **Project:** \`${VERCEL_PROJECT_ID}\`"
echo "- **Owner (accountId):** \`${VERCEL_OWNER_ID:-unknown}\`"
echo "- **Window:** $(vercel_md_fmt_ms "$WIN_START_MS") → $(vercel_md_fmt_ms "$WIN_END_MS")"
echo "- **Filter:** environment=\`${ENVIRONMENT_FILTER}\`"
echo "- **Caps:** max_rows=${MAX_ROWS}, max_pages=${MAX_PAGES}"
echo "- **Endpoint:** \`GET https://vercel.com/api/logs/request-logs\` (paginated; same one the Vercel dashboard 'Logs' page uses)"
echo

case "${VERCEL_API_STATUS:-ok}" in
  ok)
    : ;;
  missing-token|missing-owner-id|api-error)
    echo "**Status:** ${VERCEL_API_STATUS} — see runbook issue panel for details."
    if [[ -n "${VERCEL_API_ERROR:-}" ]]; then
      echo
      echo '```'
      printf '%s\n' "$VERCEL_API_ERROR" | head -c 800
      echo '```'
    fi
    exit 0
    ;;
  *)
    echo "**Status:** unexpected (${VERCEL_API_STATUS})."
    exit 0
    ;;
esac

ROW_COUNT="${VERCEL_REQUEST_LOG_ROW_COUNT:-$(jq 'length' "$ROWS_FILE" 2>/dev/null || echo 0)}"
ROW_COUNT="${ROW_COUNT:-0}"

# Build a small debug summary: per-status / per-source / per-deployment counts.
jq -c --argjson row_count "$ROW_COUNT" '
  {
    total_normalized_rows: $row_count,
    by_status_class: (
      [
        {label: "2xx", count: (map(select(.code >= 200 and .code < 300)) | length)},
        {label: "3xx", count: (map(select(.code >= 300 and .code < 400)) | length)},
        {label: "4xx", count: (map(select(.code >= 400 and .code < 500)) | length)},
        {label: "5xx", count: (map(select(.code >= 500 and .code < 600)) | length)}
      ]
    ),
    sources:      (map(.source // "" | select(. != "")) | unique),
    domains:      (map(.domain // "" | select(. != "")) | unique | .[0:10]),
    environments: (map(.environment // "" | select(. != "")) | unique),
    deployments:  (
      group_by(.deployment_id // "")
      | map({deployment_id: .[0].deployment_id, rows: length})
      | sort_by(-.rows)
      | .[0:10]
    )
  }
' "$ROWS_FILE" >"$DEBUG_FILE"

if [[ "$ROW_COUNT" == "0" ]]; then
  echo "**Status:** endpoint responded; **0 rows** in this window."
  echo
  echo "_This is normal for low-traffic projects, narrow lookbacks, or production-only filters. Reduce \`VERCEL_REQUEST_LOGS_ENV\` to \`all\` or widen \`TIME_WINDOW_HOURS\` to broaden the search._"
else
  echo "**Status:** collected **${ROW_COUNT}** normalized rows."
  echo
  echo "### Class breakdown"
  echo
  echo "| Class | Count |"
  echo "| --- | ---: |"
  jq -r '.by_status_class[] | "| \(.label) | \(.count) |"' "$DEBUG_FILE"
  echo
  TOP_DEPLOYMENTS_LEN="$(jq '.deployments | length' "$DEBUG_FILE" 2>/dev/null || echo 0)"
  if [[ "${TOP_DEPLOYMENTS_LEN:-0}" -gt 0 ]]; then
    echo "### Top deployments by row count"
    echo
    echo "| Deployment | Rows |"
    echo "| --- | ---: |"
    jq -r '.deployments[] | "| `\(.deployment_id // "-")` | \(.rows) |"' "$DEBUG_FILE"
    echo
  fi
  echo "_Aggregator tasks (4xx / 5xx / other) read \`vercel_request_log_rows.json\` directly — no further API calls._"
fi
