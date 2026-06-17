#!/usr/bin/env bash
# Shared helpers for Vercel REST API (runtime logs, project resolution).
VERCEL_API="${VERCEL_API:-https://api.vercel.com}"

vercel_resolve_token() {
  if [ -n "${VERCEL_TOKEN:-}" ]; then
    return 0
  fi
  if [ -n "${vercel_api_token:-}" ] && [ -f "${vercel_api_token}" ]; then
    VERCEL_TOKEN="$(cat "${vercel_api_token}")"
    export VERCEL_TOKEN
    return 0
  fi
  return 1
}

vercel_quote_path() {
  python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

# GET ${VERCEL_API}${path} -> writes body to $2, prints HTTP status code to stdout.
vercel_curl_get_body() {
  local path="$1"
  local out="$2"
  local err="$3"
  local code
  code="$(
    curl -sS -o "$out" -w "%{http_code}" \
      -H "Authorization: Bearer ${VERCEL_TOKEN}" \
      "${VERCEL_API}${path}" 2>"$err"
  )" || true
  echo "${code:-000}"
}

# Sets VERCEL_PROJECT_ID from VERCEL_PROJECT + VERCEL_TEAM_ID. Returns 0 on success.
vercel_resolve_project_id() {
  local enc_p enc_team
  enc_p=$(vercel_quote_path "${VERCEL_PROJECT}")
  enc_team=$(vercel_quote_path "${VERCEL_TEAM_ID}")
  local path="/v9/projects/${enc_p}?teamId=${enc_team}"
  local body rc
  body="$(mktemp)"
  local cerr
  cerr="$(mktemp)"
  rc="$(vercel_curl_get_body "$path" "$body" "$cerr")"
  if [ "$rc" != "200" ]; then
    cat "$body"
    rm -f "$body" "$cerr"
    return 1
  fi
  VERCEL_PROJECT_ID="$(jq -r '.id // empty' "$body")"
  rm -f "$body" "$cerr"
  if [ -z "$VERCEL_PROJECT_ID" ] || [ "$VERCEL_PROJECT_ID" = "null" ]; then
    return 1
  fi
  export VERCEL_PROJECT_ID
  return 0
}

# Sets VERCEL_DEPLOYMENT_ID to latest READY production deployment.
vercel_resolve_production_deployment() {
  local enc_team enc_proj
  enc_team=$(vercel_quote_path "${VERCEL_TEAM_ID}")
  enc_proj=$(vercel_quote_path "${VERCEL_PROJECT_ID}")
  local path="/v6/deployments?teamId=${enc_team}&projectId=${enc_proj}&target=production&state=READY&limit=1"
  local body rc
  body="$(mktemp)"
  local cerr
  cerr="$(mktemp)"
  rc="$(vercel_curl_get_body "$path" "$body" "$cerr")"
  if [ "$rc" != "200" ]; then
    cat "$body"
    rm -f "$body" "$cerr"
    return 1
  fi
  VERCEL_DEPLOYMENT_ID="$(jq -r '.deployments[0].uid // .deployments[0].id // empty' "$body")"
  rm -f "$body" "$cerr"
  if [ -z "$VERCEL_DEPLOYMENT_ID" ] || [ "$VERCEL_DEPLOYMENT_ID" = "null" ]; then
    return 1
  fi
  export VERCEL_DEPLOYMENT_ID
  return 0
}

# Fetch runtime logs into file (bounded). Uses project id + deployment id.
vercel_fetch_runtime_logs_file() {
  local out_file="$1"
  local max_lines="${LOG_SAMPLE_MAX_LINES:-50000}"
  local max_time="${LOG_FETCH_MAX_SECONDS:-90}"
  local enc_team enc_proj enc_dep
  enc_team=$(vercel_quote_path "${VERCEL_TEAM_ID}")
  enc_proj=$(vercel_quote_path "${VERCEL_PROJECT_ID}")
  enc_dep=$(vercel_quote_path "${VERCEL_DEPLOYMENT_ID}")
  local path="/v1/projects/${enc_proj}/deployments/${enc_dep}/runtime-logs?teamId=${enc_team}"
  : >"$out_file"
  curl -sS --max-time "$max_time" \
    -H "Authorization: Bearer ${VERCEL_TOKEN}" \
    "${VERCEL_API}${path}" 2>/dev/null | head -n "$max_lines" >"$out_file" || true
}

# Normalize stream lines to one JSON object per line (strip SSE data: prefix).
vercel_normalize_ndjson() {
  local raw="$1"
  local norm="$2"
  : >"$norm"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [ -z "$line" ] && continue
    if [[ "$line" == data:* ]]; then
      line="${line#data: }"
    fi
    echo "$line" >>"$norm"
  done <"$raw"
}
