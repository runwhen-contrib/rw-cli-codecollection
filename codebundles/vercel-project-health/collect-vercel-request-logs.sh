#!/usr/bin/env bash
# Collect normalized HTTP request rows for the configured project over the
# lookback window using Vercel's historical request-logs endpoint:
#
#   GET https://vercel.com/api/logs/request-logs
#       ?projectId=...&ownerId=...&startDate=<ms>&endDate=<ms>&page=N
#       [&environment=production][&statusCode=...][&deploymentId=...]
#
# This is the same endpoint the Vercel dashboard's "Logs" page and `vercel logs`
# v2 use. It IS time-range queryable (unlike /v1/runtime-logs which is live-tail
# only) and returns paginated JSON: `{rows: [...], hasMoreRows: bool}`. Stable
# enough that the official CLI ships with it on `main`, but technically
# undocumented and subject to change. See README for retention notes (~3d) and
# Log Drains as a longer-retention alternative.
#
# Outputs to $VERCEL_ARTIFACT_DIR (default `.`):
#   vercel_request_log_rows.json            — array of normalized rows
#                                             {ts, code, path, method, source,
#                                              domain, level, deployment_id,
#                                              branch, environment, duration_ms,
#                                              cache, region, error_code}
#   vercel_request_log_rows.debug.json      — counts + sampled metadata
#   vercel_request_log_rows_issues.json     — issue array consumed by runbook.robot
#
# stdout: a markdown report block embedded into the runbook report.

set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=vercel-helpers.sh
source "${SCRIPT_DIR}/vercel-helpers.sh"

vercel_artifact_prepare
ARTIFACT_DIR="$(vercel_artifact_dir)"
ROWS_FILE="${ARTIFACT_DIR}/vercel_request_log_rows.json"
DEBUG_FILE="${ARTIFACT_DIR}/vercel_request_log_rows.debug.json"
ISSUES_FILE="${ARTIFACT_DIR}/vercel_request_log_rows_issues.json"
RAW_FILE="$(mktemp)"
ERR_FILE="$(mktemp)"
trap 'rm -f "$RAW_FILE" "$ERR_FILE" 2>/dev/null || true' EXIT

ENVIRONMENT_FILTER="${VERCEL_REQUEST_LOGS_ENV:-production}"
MAX_ROWS="${VERCEL_REQUEST_LOGS_MAX_ROWS:-5000}"
MAX_PAGES="${VERCEL_REQUEST_LOGS_MAX_PAGES:-20}"

vercel_compute_window_ms

PROJECT_RAW="${VERCEL_PROJECT_ID:?VERCEL_PROJECT_ID is required}"
PROJECT_ID="$(vercel_resolve_project_id_cached)" || PROJECT_ID="$PROJECT_RAW"
OWNER_ID="$(vercel_resolve_owner_id_cached || true)"

echo "## Vercel request logs"
echo
echo "- **Project:** \`${PROJECT_RAW}\`  → \`${PROJECT_ID}\`"
echo "- **Owner (accountId):** \`${OWNER_ID:-unknown}\`"
echo "- **Window:** $(vercel_md_fmt_ms "$WIN_START_MS") → $(vercel_md_fmt_ms "$WIN_END_MS")"
echo "- **Filter:** environment=\`${ENVIRONMENT_FILTER}\`"
echo "- **Caps:** max_rows=${MAX_ROWS}, max_pages=${MAX_PAGES}"
echo "- **Endpoint:** \`GET https://vercel.com/api/logs/request-logs\` (paginated; same one the Vercel dashboard 'Logs' page uses)"
echo

# Initialize empty artifacts so downstream tasks always have something to read.
echo '[]' >"$ROWS_FILE"
echo '{}' >"$DEBUG_FILE"
echo '[]' >"$ISSUES_FILE"

if [[ -z "$OWNER_ID" ]]; then
  ISSUE_TITLE="Missing Vercel ownerId for project \`${PROJECT_RAW}\` — historical request-logs unavailable"
  ISSUE_DETAILS="The historical request-logs endpoint requires the project's ownerId (team_... or user_...). Could not resolve it from the cached project config or a live get-project lookup. Check that the Fetch Vercel Project Configuration task ran first or set VERCEL_OWNER_ID explicitly."
  ISSUE_NEXT_STEPS="Re-run the project-config task (it caches accountId), confirm the token has read access to the project, or set VERCEL_OWNER_ID."
  jq -n --arg t "$ISSUE_TITLE" --arg d "$ISSUE_DETAILS" --arg n "$ISSUE_NEXT_STEPS" \
    '[{severity: 3, title: $t, details: $d, next_steps: $n}]' >"$ISSUES_FILE"
  echo "**Status:** could not resolve ownerId — skipping log fetch."
  exit 0
fi

ENV_ARG=()
if [[ -n "$ENVIRONMENT_FILTER" && "$ENVIRONMENT_FILTER" != "all" ]]; then
  ENV_ARG=(--environment "$ENVIRONMENT_FILTER")
fi

if vercel_py request-logs \
    --project-id "$PROJECT_ID" \
    --owner-id "$OWNER_ID" \
    --since-ms "$WIN_START_MS" \
    --until-ms "$WIN_END_MS" \
    "${ENV_ARG[@]}" \
    --max-rows "$MAX_ROWS" \
    --max-pages "$MAX_PAGES" \
    --normalize \
    --error-out "$ERR_FILE" \
    --out "$RAW_FILE" 2>>"$ERR_FILE"; then
  cp "$RAW_FILE" "$ROWS_FILE"
else
  ERR_TEXT="$(head -c 800 "$ERR_FILE" | sed 's/[[:cntrl:]]//g')"
  ISSUE_TITLE="Vercel request-logs query failed for project \`${PROJECT_RAW}\`"
  ISSUE_DETAILS="The dashboard-backing request-logs endpoint did not return rows. First ~800 bytes of the error: ${ERR_TEXT}"
  ISSUE_NEXT_STEPS="Verify the token has access to the project; confirm projectId=\`${PROJECT_ID}\` and ownerId=\`${OWNER_ID}\`; if the endpoint behavior changed, run /tmp/validate-vercel-request-logs.sh or the smoke test (/tmp/smoke-vercel-request-logs-cli.sh) to inspect the raw response."
  jq -n --arg t "$ISSUE_TITLE" --arg d "$ISSUE_DETAILS" --arg n "$ISSUE_NEXT_STEPS" \
    '[{severity: 3, title: $t, details: $d, next_steps: $n}]' >"$ISSUES_FILE"
  echo "**Status:** request-logs query failed — see issue."
  echo
  echo '```'
  echo "$ERR_TEXT"
  echo '```'
  exit 0
fi

ROW_COUNT="$(jq 'length' "$ROWS_FILE" 2>/dev/null || echo 0)"
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
  echo "**Status:** ✅ endpoint responded; **0 rows** in this window."
  echo
  echo "_This is normal for low-traffic projects, narrow lookbacks, or production-only filters. Reduce \`VERCEL_REQUEST_LOGS_ENV\` to \`all\` or widen \`TIME_WINDOW_HOURS\` to broaden the search._"
else
  echo "**Status:** ✅ collected **${ROW_COUNT}** normalized rows."
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
