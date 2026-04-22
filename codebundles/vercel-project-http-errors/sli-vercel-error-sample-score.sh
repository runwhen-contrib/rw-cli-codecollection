#!/usr/bin/env bash
# SLI dimension: runtime log sample should not exceed SLI_MAX_ERROR_EVENTS unhealthy responses in the window.
set -euo pipefail
set -x

: "${VERCEL_PROJECT_ID:?Must set VERCEL_PROJECT_ID}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vercel-http-lib.sh
source "${SCRIPT_DIR}/vercel-http-lib.sh"

if [[ -z "$(vercel_token_value)" ]]; then
  echo '{"score":0}'
  exit 0
fi

export DEPLOYMENT_ENVIRONMENT="$(printf '%s' "${DEPLOYMENT_ENVIRONMENT:-production}" | tr '[:upper:]' '[:lower:]')"
export RUNTIME_LOG_MAX_LINES_PER_DEPLOYMENT="${SLI_LOG_LINE_CAP:-800}"
thresh="${SLI_MAX_ERROR_EVENTS:-25}"

vercel_compute_window_ms
NOW_MS="$WIN_END_MS"

tmp_deps="$(mktemp)"
if ! vercel_fetch_deployments_all "$tmp_deps"; then
  echo '{"score":0}'
  rm -f "$tmp_deps"
  exit 0
fi

ids_json="$(vercel_select_deployments_for_window "$tmp_deps" "$NOW_MS" "$WIN_START_MS" "$WIN_END_MS")"
rm -f "$tmp_deps"

if [[ "$(echo "$ids_json" | jq 'length // 0')" -eq 0 ]]; then
  echo '{"score":0}'
  exit 0
fi

first_id="$(echo "$ids_json" | jq -r '.[0]')"
bad=0
while IFS= read -r raw; do
  [[ -z "$raw" ]] && continue
  norm=$(printf '%s' "$raw" | vercel_normalize_log_line)
  [[ -z "$norm" ]] && continue
  if printf '%s' "$norm" | jq -e --argjson ws "$WIN_START_MS" --argjson we "$WIN_END_MS" 'select(.ts >= $ws and .ts <= $we)' >/dev/null 2>&1; then
    if printf '%s' "$norm" | jq -e 'select(.code >= 400)' >/dev/null 2>&1; then
      bad=$((bad + 1))
    fi
  fi
done < <(vercel_stream_runtime_logs "$first_id" || true)

if [[ "$bad" -le "$thresh" ]]; then
  echo '{"score":1}'
else
  echo '{"score":0}'
fi
