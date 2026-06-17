#!/usr/bin/env bash
# shellcheck disable=SC1091
# Shared analysis helpers (sourced from task scripts).

vercel_compute_since_until_ms() {
  local lookback="${LOOKBACK_MINUTES:-60}"
  local now_ms
  now_ms="$(python3 -c "import time; print(int(time.time()*1000))")"
  local span_ms=$((lookback * 60 * 1000))
  SINCE_MS=$((now_ms - span_ms))
  UNTIL_MS=$now_ms
}

# Sets VERCEL_PROJECT_ID, VERCEL_DEPLOYMENT_ID from API (requires vercel-lib.sh).
vercel_resolve_project_and_deployment_ids() {
  local enc_proj enc_tid url raw http_code body dep
  enc_proj="$(vercel_urlencode "${VERCEL_PROJECT}")"
  enc_tid="$(vercel_urlencode "${VERCEL_TEAM_ID}")"
  url="${VERCEL_API_BASE}/v9/projects/${enc_proj}?teamId=${enc_tid}"
  raw="$(vercel_http_get "$url")" || return 1
  http_code=$(echo "$raw" | tail -n1)
  body=$(echo "$raw" | sed '$d')
  if [ "$http_code" != "200" ]; then
    echo "resolve_error: project HTTP ${http_code}" >&2
    return 1
  fi
  VERCEL_PROJECT_ID=$(echo "$body" | jq -r '.id // empty')
  dep="$(vercel_latest_production_deployment_json "$VERCEL_PROJECT_ID")" || return 1
  if [ -z "$dep" ] || [ "$dep" = "null" ]; then
    echo "resolve_error: no production deployment" >&2
    return 1
  fi
  VERCEL_DEPLOYMENT_ID=$(echo "$dep" | jq -r '.uid // empty')
}

# Filter request rows in time window; excludes delimiter rows without status.
vercel_filter_request_logs_json() {
  local file="$1"
  local since_ms="$2"
  if [ ! -s "$file" ]; then
    echo "[]"
    return 0
  fi
  # One JSON object per line (NDJSON); avoids failures on empty files (handled above).
  jq -n --argjson since "$since_ms" '
    [ inputs
      | select(type == "object")
      | select((.timestampInMs | tonumber?) // 0 >= $since)
      | select((.source | tostring) != "delimiter")
      | select((.responseStatusCode | type) == "number")
    ]
  ' "$file"
}
