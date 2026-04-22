#!/usr/bin/env bash
# Shared helpers for Vercel REST API (curl + jq). Sourced by task scripts.
VERCEL_API="${VERCEL_API:-https://api.vercel.com}"

vercel_token_value() {
  local tok="${VERCEL_TOKEN:-${vercel_token:-}}"
  printf '%s' "$tok"
}

vercel_team_qs() {
  if [[ -n "${VERCEL_TEAM_ID:-}" ]]; then
    printf '%s' "teamId=$(printf '%s' "${VERCEL_TEAM_ID}" | jq -sRr @uri)"
  fi
}

vercel_fetch_deployments_all() {
  local out_file="$1"
  local auth
  auth="$(vercel_auth_header)" || return 1
  local base="${VERCEL_API}/v6/deployments"
  local qs="projectId=$(printf '%s' "${VERCEL_PROJECT_ID}" | jq -sRr @uri)&limit=100"
  local tq
  tq="$(vercel_team_qs)"
  [[ -n "$tq" ]] && qs="${qs}&${tq}"
  local dep_env
  dep_env="$(printf '%s' "${DEPLOYMENT_ENVIRONMENT:-production}" | tr '[:upper:]' '[:lower:]')"
  case "$dep_env" in
    production) qs="${qs}&target=production" ;;
    preview) qs="${qs}&target=preview" ;;
    all|*) ;;
  esac

  local url="${base}?${qs}"
  local tmp
  tmp="$(mktemp)"
  local page=0
  while [[ "$page" -lt 15 ]]; do
    page=$((page + 1))
    local http
    http=$(curl -sS --max-time 120 -w '%{http_code}' -o "$tmp.r" -H "$auth" "$url") || true
    if [[ "$http" != "200" ]]; then
      echo "Vercel deployments list failed: HTTP ${http} $(head -c 500 "$tmp.r" 2>/dev/null || true)" >&2
      rm -f "$tmp" "$tmp.r"
      return 1
    fi
    jq -c '.deployments[]?' "$tmp.r" >>"$tmp" 2>/dev/null || true
    local next
    next="$(jq -r '.pagination.next // empty' "$tmp.r")"
    if [[ -z "$next" ]]; then
      break
    fi
    url="$next"
  done
  if [[ ! -s "$tmp" ]]; then
    echo '{"deployments":[]}' >"$out_file"
  else
    jq -s '{deployments: .}' "$tmp" >"$out_file"
  fi
  rm -f "$tmp" "$tmp.r"
}

vercel_auth_header() {
  local tok
  tok="$(vercel_token_value)"
  if [[ -z "$tok" ]]; then
    return 1
  fi
  printf 'Authorization: Bearer %s' "$tok"
}

vercel_compute_window_ms() {
  local hours="${TIME_WINDOW_HOURS:-24}"
  WIN_END_MS="$(date +%s)000"
  WIN_START_MS=$((WIN_END_MS / 1000 - hours * 3600))000
  export WIN_START_MS WIN_END_MS
}

vercel_select_deployments_for_window() {
  local in_file="$1"
  local now_ms="$2"
  local ws="$3"
  local we="$4"
  local env="${DEPLOYMENT_ENVIRONMENT:-production}"
  local maxd="${MAX_DEPLOYMENTS_TO_SCAN:-10}"

  jq -r --argjson now_ms "$now_ms" --argjson ws "$ws" --argjson we "$we" --arg env "$env" --argjson maxd "$maxd" '
    def start_ms(d): ((d.createdAt // d.created // 0) | tonumber);
    def tgt(d): (d.target // "preview");
    def ready(d): ((d.readyState // d.state // "") == "READY");
    (.deployments // [])
    | map(select(ready))
    | map({
        uid: .uid,
        createdAt: start_ms(.),
        target: tgt(.)
      })
    | map(select(
        if $env == "production" then .target == "production"
        elif $env == "preview" then (.target != "production")
        else true end
      ))
    | sort_by(.createdAt)
    | . as $arr
    | [
        range(0; ($arr | length)) as $i
        | $arr[$i] as $d
        | ([
            $arr[] | select(.target == $d.target and .createdAt > $d.createdAt)
          ] | min_by(.createdAt) | .createdAt // $now_ms) as $end
        | select($d.createdAt < $we and $end > $ws)
        | {uid: $d.uid, start: $d.createdAt, end: $end, target: $d.target}
      ]
    | sort_by(-.start)
    | .[0:($maxd | tonumber)]
    | [.[] | .uid]
    | @json
  ' "$in_file"
}

vercel_stream_runtime_logs() {
  local dep_id="$1"
  local auth
  auth="$(vercel_auth_header)" || return 1
  local line_cap="${RUNTIME_LOG_MAX_LINES_PER_DEPLOYMENT:-10000}"
  local url="${VERCEL_API}/v1/projects/${VERCEL_PROJECT_ID}/deployments/${dep_id}/runtime-logs"
  local tq
  tq="$(vercel_team_qs)"
  [[ -n "$tq" ]] && url="${url}?${tq}"

  local http
  http=$(curl -sS --max-time 180 -w '%{http_code}' -H "$auth" -H "Accept: application/stream+json" -o /tmp/vrl.$$."$dep_id" "$url") || true
  if [[ "$http" != "200" ]]; then
    echo "runtime-logs HTTP ${http} for ${dep_id}" >&2
    return 1
  fi
  local n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" == data:* ]] && line="${line#data: }"
    printf '%s\n' "$line"
    n=$((n + 1))
    if [[ "$n" -ge "$line_cap" ]]; then
      break
    fi
  done < /tmp/vrl.$$."$dep_id"
  rm -f /tmp/vrl.$$."$dep_id"
}

vercel_normalize_log_line() {
  jq -c '
    {
      ts: ((.timestampInMs // .timestamp // 0) | tonumber),
      code: ((.responseStatusCode // .status // 0) | tonumber),
      path: (.requestPath // .path // ""),
      method: ((.requestMethod // .method // "GET") | ascii_upcase)
    }
  ' 2>/dev/null || true
}

vercel_aggregate_status_bucket() {
  local dep_ids_json="$1"
  local match_jq="$2"
  local out_paths_tmp="$3"
  rm -f "$out_paths_tmp"
  : >"$out_paths_tmp"
  local id
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    while IFS= read -r raw; do
      [[ -z "$raw" ]] && continue
      local norm
      norm=$(printf '%s' "$raw" | vercel_normalize_log_line)
      [[ -z "$norm" ]] && continue
      if printf '%s' "$norm" | jq -e --argjson ws "${WIN_START_MS}" --argjson we "${WIN_END_MS}" \
        'select(.ts >= $ws and .ts <= $we)' >/dev/null 2>&1; then
        if printf '%s' "$norm" | jq -e "$match_jq" >/dev/null 2>&1; then
          printf '%s\n' "$norm" >>"$out_paths_tmp"
        fi
      fi
    done < <(vercel_stream_runtime_logs "$id" || true)
  done < <(echo "$dep_ids_json" | jq -r '.[]')
}

vercel_paths_summary_jq() {
  jq -s '
    if length == 0 then []
    else
      group_by(.path + "\u001f" + .method)
      | map({
          path: .[0].path,
          method: .[0].method,
          count: length,
          sample_ts: [.[].ts] | sort | .[0:5]
        })
      | sort_by(-.count)
    end
  '
}
