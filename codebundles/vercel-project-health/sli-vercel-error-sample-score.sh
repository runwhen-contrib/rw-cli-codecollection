#!/usr/bin/env bash
# SLI dimension: how many error-class (status >= 400) request-log rows the
# project produced over the last SLI_LOOKBACK_HOURS, capped by a small page
# fetch.
#
# Uses the historical request-logs endpoint (the same one the Vercel
# dashboard's Logs page uses) — NOT the live-tail /v1/runtime-logs endpoint.
# We ask the server for status>=400 only, page=0, max-rows=SLI_MAX_ROWS so a
# busy project doesn't blow our wall-clock budget. The endpoint returns
# normalized timestamps + status codes; we only need the row count.
#
# Output: a single JSON object on stdout with:
#   error_sample_count : count of status>=400 rows seen in the window (capped)
#   capped             : true when SLI_MAX_ROWS was reached (potential undercount)
#   reason             : optional skip reason ("missing-owner-id", "api-error", ...)
#   details            : raw counts + window for the report

set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=vercel-helpers.sh
source "${SCRIPT_DIR}/vercel-helpers.sh"

emit() {
  jq -n \
    --argjson count "${1:-0}" \
    --argjson capped "${2:-false}" \
    --arg reason "${3:-}" \
    --argjson details "${4:-null}" \
    '{
       error_sample_count: $count,
       capped: $capped,
       reason: ($reason // ""),
       details: ($details // {})
     }'
}

if [[ -z "$(vercel_token_value)" ]]; then
  emit 0 false "vercel_token-missing"
  exit 0
fi

PROJECT_RAW="${VERCEL_PROJECT_ID:?VERCEL_PROJECT_ID required}"
PROJECT_ID="$(vercel_resolve_project_id_cached)" || PROJECT_ID="$PROJECT_RAW"
OWNER_ID="$(vercel_resolve_owner_id_cached || true)"

if [[ -z "$OWNER_ID" ]]; then
  emit 0 false "missing-owner-id" \
    "$(jq -n --arg p "$PROJECT_RAW" '{project_id: $p, hint: "Run report-vercel-project-config.sh first to cache accountId, or set VERCEL_OWNER_ID."}')"
  exit 0
fi

LOOKBACK_HOURS="${SLI_LOOKBACK_HOURS:-${TIME_WINDOW_HOURS:-24}}"
MAX_ROWS="${SLI_MAX_ROWS:-200}"
ENVIRONMENT_FILTER="${VERCEL_REQUEST_LOGS_ENV:-production}"

NOW_MS=$(( $(date +%s) * 1000 ))
WIN_START_MS=$(( NOW_MS - LOOKBACK_HOURS * 3600 * 1000 ))

raw_tmp="$(mktemp)"
err_tmp="$(mktemp)"
trap 'rm -f "$raw_tmp" "$err_tmp" 2>/dev/null || true' EXIT

ENV_ARG=()
if [[ -n "$ENVIRONMENT_FILTER" && "$ENVIRONMENT_FILTER" != "all" ]]; then
  ENV_ARG=(--environment "$ENVIRONMENT_FILTER")
fi

if ! vercel_py request-logs \
    --project-id "$PROJECT_ID" \
    --owner-id "$OWNER_ID" \
    --since-ms "$WIN_START_MS" \
    --until-ms "$NOW_MS" \
    "${ENV_ARG[@]}" \
    --status-code 400 \
    --max-rows "$MAX_ROWS" \
    --max-pages 1 \
    --error-out "$err_tmp" \
    --out "$raw_tmp" 2>>"$err_tmp"; then
  blob="$(head -c 400 "$err_tmp" | sed 's/[[:cntrl:]]//g')"
  emit 0 false "api-error" \
    "$(jq -n --arg b "$blob" '{error: $b}')"
  exit 0
fi

COUNT="$(jq 'length' "$raw_tmp" 2>/dev/null || echo 0)"
COUNT="${COUNT:-0}"
CAPPED="false"
if [[ "$COUNT" -ge "$MAX_ROWS" ]]; then
  CAPPED="true"
fi

DETAILS="$(jq --argjson hrs "$LOOKBACK_HOURS" --argjson max "$MAX_ROWS" --arg env "$ENVIRONMENT_FILTER" '
  {
    rows_examined: length,
    lookback_hours: $hrs,
    page_max_rows: $max,
    environment: $env,
    distinct_codes: ([.[].statusCode] | unique),
    distinct_paths: ([.[].requestPath] | unique | .[0:10])
  }
' "$raw_tmp" 2>/dev/null || echo '{}')"

emit "$COUNT" "$CAPPED" "" "$DETAILS"
