#!/usr/bin/env bash
# Shared helpers for Vercel HTTP error health checks.
VERCEL_API_BASE="${VERCEL_API_BASE:-https://api.vercel.com}"

vercel_urlencode() {
  python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

vercel_bearer_header() {
  if [ -z "${VERCEL_API_TOKEN:-}" ]; then
    echo "vercel_lib_error: VERCEL_API_TOKEN is not set" >&2
    return 1
  fi
  printf '%s' "Authorization: Bearer ${VERCEL_API_TOKEN}"
}

# Fetch project JSON; prints HTTP status code as last line (after a NUL not used) — use split below.
vercel_http_get() {
  local url="$1"
  local hdr
  hdr="$(vercel_bearer_header)" || return 1
  curl -sS --max-time 60 -H "$hdr" -H "Accept: application/json" -w "\n%{http_code}" "$url"
}

vercel_latest_production_deployment_json() {
  local pid="$1"
  local enc_pid tid url raw
  enc_pid="$(vercel_urlencode "$pid")"
  tid="$(vercel_urlencode "${VERCEL_TEAM_ID}")"
  url="${VERCEL_API_BASE}/v6/deployments?projectId=${enc_pid}&teamId=${tid}&target=production&limit=15"
  raw="$(vercel_http_get "$url")" || return 1
  local code body
  code=$(echo "$raw" | tail -n1)
  body=$(echo "$raw" | sed '$d')
  if [ "$code" != "200" ]; then
    echo "{\"error\":\"deployments_list_failed\",\"httpStatus\":${code},\"body\":$(echo "$body" | jq -Rs .)}" >&2
    return 1
  fi
  echo "$body" | jq -c '[.deployments[] | select(.readyState == "READY")] | sort_by(.createdAt // .created // "") | reverse | .[0] // empty'
}

# Download runtime logs (NDJSON lines) into file; truncates to max_lines.
vercel_fetch_runtime_logs_file() {
  local project_id="$1"
  local deployment_id="$2"
  local since_ms="$3"
  local until_ms="$4"
  local out_file="$5"
  local max_lines="${6:-5000}"
  local hdr enc_p enc_d tid url
  hdr="$(vercel_bearer_header)" || return 1
  enc_p="$(vercel_urlencode "$project_id")"
  enc_d="$(vercel_urlencode "$deployment_id")"
  tid="$(vercel_urlencode "${VERCEL_TEAM_ID}")"
  url="${VERCEL_API_BASE}/v1/projects/${enc_p}/deployments/${enc_d}/runtime-logs?teamId=${tid}&since=${since_ms}&until=${until_ms}&limit=${max_lines}"
  curl -sS --max-time 120 -H "$hdr" -H "Accept: application/stream+json" "$url" | head -n "$max_lines" >"$out_file"
}
