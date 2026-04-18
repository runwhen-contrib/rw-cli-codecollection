#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Shared helpers for LiteLLM proxy Admin API calls (sourced by task scripts).
#
# Contract for callers:
#   source litellm-http-helpers.sh
#   litellm_init_runtime   # once, at the top of the script
#   # ... then use litellm_base_url / litellm_master_token / litellm_get_file
#
# litellm_init_runtime does two things:
#
#   1. Ensure PROXY_BASE_URL is set. If empty, _portforward_helper.sh starts a
#      kubectl port-forward against svc/${LITELLM_SERVICE_NAME} on
#      ${LITELLM_HTTP_PORT:-4000} and exports PROXY_BASE_URL=http://127.0.0.1:<port>.
#      A trap is registered so the port-forward is torn down on exit.
#      IMPORTANT: this must run in the main shell (not in a $() subshell) so
#      the background port-forward PID is reachable for cleanup.
#
#   2. Ensure LITELLM_MASTER_KEY is set. Reads the cache file written by Suite
#      Setup (./.litellm_master_key) or falls back to the full derivation
#      chain (env, RW secret, named K8s Secret, Pod env inference, kubectl
#      exec fallback, Secret name-pattern search). See _master_key_helper.sh.
#
# After init the accessors below just echo the already-resolved values, so
# `base="$(litellm_base_url)"` is safe and never emits status chatter.
#
# Requires: curl, jq, python3 (python3 only for date-range math).
# -----------------------------------------------------------------------------

SCRIPT_DIR_LITELLM_HTTP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR_LITELLM_HTTP}/_portforward_helper.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR_LITELLM_HTTP}/_master_key_helper.sh"

# Idempotent one-time runtime bootstrap. Safe to call multiple times.
litellm_init_runtime() {
  if [[ "${_LITELLM_RUNTIME_INITIALIZED:-0}" == "1" ]]; then
    return 0
  fi

  if [[ -z "${PROXY_BASE_URL:-}" ]]; then
    ensure_proxy_base_url || return 1
  fi

  if [[ -z "${LITELLM_MASTER_KEY:-}" ]]; then
    # resolve_master_key never fails; on failure it leaves LITELLM_MASTER_KEY
    # empty and callers decide how to handle that.
    resolve_master_key || true
  fi

  _LITELLM_RUNTIME_INITIALIZED=1
  return 0
}

litellm_base_url() {
  local u="${PROXY_BASE_URL:-}"
  if [[ -z "$u" ]]; then
    echo "PROXY_BASE_URL not set (call litellm_init_runtime first)" >&2
    return 1
  fi
  printf '%s' "${u%/}"
}

litellm_master_token() {
  local t="${LITELLM_MASTER_KEY:-${litellm_master_key:-}}"
  if [[ -z "$t" ]]; then
    echo "litellm_master_key could not be resolved (call litellm_init_runtime or supply via RW secret / Pod env / K8s Secret)" >&2
    return 1
  fi
  printf '%s' "$t"
}

# Prints: START_DATE END_DATE (YYYY-MM-DD) for LiteLLM spend routes.
litellm_date_range() {
  python3 - <<'PY'
import os, re, datetime
w = os.environ.get("RW_LOOKBACK_WINDOW", "24h").strip()
now = datetime.datetime.utcnow()
end = now.date()
if m := re.match(r"^(\d+)h$", w, re.I):
    delta = datetime.timedelta(hours=int(m.group(1)))
elif m := re.match(r"^(\d+)d$", w, re.I):
    delta = datetime.timedelta(days=int(m.group(1)))
elif m := re.match(r"^(\d+)m$", w, re.I):
    delta = datetime.timedelta(minutes=int(m.group(1)))
else:
    delta = datetime.timedelta(hours=24)
start_dt = now - delta
start = start_dt.date()
print(start.isoformat(), end.isoformat())
PY
}

# GET path (path begins with /). Writes body to file, prints HTTP code to stdout.
litellm_get_file() {
  local path="$1"
  local out="$2"
  local base
  base="$(litellm_base_url)" || return 1
  local tok
  tok="$(litellm_master_token)" || return 1
  local url="${base}${path}"
  curl -sS --max-time 120 -o "$out" -w "%{http_code}" \
    -H "Authorization: Bearer ${tok}" \
    -H "Accept: application/json" \
    "$url"
}
