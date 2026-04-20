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
#
# Side effects:
#   * Opens file descriptor 3 as a dup of the script's original stdout so that
#     helper functions can emit diagnostic output that survives command
#     substitution (HTTP_CODE=$(litellm_get_file ...) would otherwise eat it).
#   * Starts kubectl port-forward if PROXY_BASE_URL is not already set, and
#     registers an EXIT trap to tear it down.
#   * Resolves LITELLM_MASTER_KEY from cache / env / RW secret / K8s Secret /
#     Pod env / kubectl exec, if not already set.
# Cleanup registry. Each entry is a shell command string that will be eval'd
# in LIFO order from the master EXIT trap installed by litellm_init_runtime.
# We use a registry (rather than each helper installing its own trap) because
# per-task scripts often install `trap 'rm -f "$TMP"' EXIT` AFTER init, which
# would otherwise clobber the port-forward cleanup.
_LITELLM_EXIT_CLEANUPS=()

# Append a cleanup command to the registry. Commands are run in LIFO order.
# Usage:
#   litellm_register_cleanup 'rm -f "$TMP"'
litellm_register_cleanup() {
  _LITELLM_EXIT_CLEANUPS+=("$*")
}

# Master EXIT/INT/TERM handler. Runs registered cleanups in reverse order so
# that resources created later are torn down first (LIFO).
_litellm_run_exit_cleanups() {
  local i
  for (( i=${#_LITELLM_EXIT_CLEANUPS[@]}-1; i>=0; i-- )); do
    eval "${_LITELLM_EXIT_CLEANUPS[$i]}" 2>/dev/null || true
  done
  _LITELLM_EXIT_CLEANUPS=()
}

litellm_init_runtime() {
  if [[ "${_LITELLM_RUNTIME_INITIALIZED:-0}" == "1" ]]; then
    return 0
  fi

  # Preserve original stdout so diagnostic output from functions called inside
  # $(...) can still reach the RW.CLI.Run Bash File captured task log.
  if ! { true >&3; } 2>/dev/null; then
    exec 3>&1
  fi

  # Install one master trap. Scripts MAY still install their own `trap ... EXIT`
  # later and that would clobber ours — which is why we ALSO encourage
  # litellm_register_cleanup. Scripts in this codebundle use it.
  trap '_litellm_run_exit_cleanups' EXIT INT TERM

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

# Emit a diagnostic line that survives command substitution. Goes to the
# saved original stdout (fd 3) if open, otherwise falls back to stderr.
_litellm_diag() {
  if { true >&3; } 2>/dev/null; then
    printf '%s\n' "$*" >&3
  else
    printf '%s\n' "$*" >&2
  fi
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

# GET path (path begins with /). Writes body to file, prints ONLY the HTTP
# status code to stdout so callers can keep the classic idiom:
#   HTTP_CODE=$(litellm_get_file "/spend/logs?..." "$TMP" || echo "000")
#
# Retries transient HTTP 000 (connection failures) LITELLM_HTTP_RETRIES times
# (default 3) with a short back-off, because kubectl port-forward can accept
# a socket on localhost before the tunnel to the pod is fully wired up.
#
# Diagnostic lines (curl stderr, retry counters, final error) are written to
# fd 3 via _litellm_diag, which is the pre-command-substitution stdout set up
# by litellm_init_runtime. This means they show up in the RW task report
# without polluting the captured HTTP code.
litellm_get_file() {
  local path="$1"
  local out="$2"
  local base
  base="$(litellm_base_url)" || { _litellm_diag "litellm_get_file: no PROXY_BASE_URL"; printf '000'; return 0; }
  local tok
  tok="$(litellm_master_token)" || { _litellm_diag "litellm_get_file: no master key"; printf '000'; return 0; }
  local url="${base}${path}"
  # Tight defaults so a single stalled endpoint cannot blow past Robot's
  # per-task subprocess timeout (180s). Worst case per call:
  #   attempts * max_time  = 2 * 20s = 40s
  # Admin API calls that don't respond within 20s are almost certainly a
  # broken backend (e.g. /spend/logs on a proxy without DB) and further
  # waiting won't help.
  local attempts="${LITELLM_HTTP_RETRIES:-2}"
  local connect_timeout="${LITELLM_CONNECT_TIMEOUT:-5}"
  local max_time="${LITELLM_MAX_TIME:-20}"
  local err_log
  err_log="$(mktemp)"
  local code=""
  local i=0
  while (( i < attempts )); do
    code=$(curl -sS --show-error \
      --connect-timeout "$connect_timeout" \
      --max-time "$max_time" \
      -o "$out" -w "%{http_code}" \
      -H "Authorization: Bearer ${tok}" \
      -H "Accept: application/json" \
      "$url" 2>"$err_log" || true)
    if [[ "$code" != "000" && -n "$code" ]]; then
      rm -f "$err_log" 2>/dev/null || true
      printf '%s' "$code"
      return 0
    fi
    if [[ -s "$err_log" ]]; then
      _litellm_diag "litellm_get_file attempt $((i+1))/${attempts} for ${url} -> HTTP ${code:-000}; curl stderr:"
      while IFS= read -r line; do
        _litellm_diag "  ${line}"
      done <"$err_log"
    else
      _litellm_diag "litellm_get_file attempt $((i+1))/${attempts} for ${url} -> HTTP ${code:-000}; no curl stderr (likely immediate reset)."
    fi
    i=$((i+1))
    sleep 1
  done
  rm -f "$err_log" 2>/dev/null || true
  printf '%s' "${code:-000}"
  return 0
}

# Returns 0 (true) if the response body in $1 looks like a LiteLLM Enterprise
# gating error — i.e. "this endpoint requires an Enterprise license". Used so
# OSS deployments can fall back to OSS-only routes or emit a harmless info
# issue instead of a hard failure.
#
# Usage:
#   if litellm_is_enterprise_gated "$BODY_FILE"; then ...
litellm_is_enterprise_gated() {
  local f="$1"
  [[ -s "$f" ]] || return 1
  # Match the canonical OSS error message patterns served by LiteLLM when an
  # Enterprise route is called without LITELLM_LICENSE.
  grep -qiE "Enterprise user|LITELLM_LICENSE|litellm\.ai/enterprise" "$f" 2>/dev/null
}

# Probes GET /health/readiness (OSS endpoint, included in every LiteLLM build)
# and caches the parsed result so callers don't thrash the proxy. This is the
# authoritative signal for "does this proxy have a spend-tracking DB wired up?"
# so HTTP 000 / 500 from /spend/logs can be disambiguated between:
#   * DB not connected     -> spend tracking is fundamentally unavailable (info)
#   * DB connected         -> transient failure (payload too big, port-forward
#                             dropped, etc.) and the caller should narrow the
#                             query or retry at a smaller scope.
#
# After calling this function, these globals are set:
#   _LITELLM_READINESS_HTTP   - HTTP status code (string, "000" on connect fail)
#   _LITELLM_READINESS_BODY   - response body (may be empty on 000)
#   _LITELLM_DB_STATUS        - "connected" | "disconnected" | "unknown"
#   _LITELLM_CACHE_TYPE       - e.g. "redis", "local", or "" if not reported
#   _LITELLM_CALLBACKS        - comma-joined success_callbacks list
#
# Returns 0 on HTTP 200, 1 otherwise.
litellm_readiness() {
  if [[ "${_LITELLM_READINESS_CACHED:-0}" == "1" ]]; then
    [[ "${_LITELLM_READINESS_HTTP:-000}" == "200" ]]
    return $?
  fi
  local base
  base="$(litellm_base_url)" || { _LITELLM_READINESS_HTTP="000"; _LITELLM_DB_STATUS="unknown"; _LITELLM_READINESS_CACHED=1; return 1; }
  local url="${base}/health/readiness"
  local tmp
  tmp="$(mktemp)"
  local auth=()
  if [[ -n "${LITELLM_MASTER_KEY:-}" ]]; then
    auth=(-H "Authorization: Bearer ${LITELLM_MASTER_KEY}")
  fi
  local code
  code=$(curl -sS --show-error \
    --connect-timeout "${LITELLM_CONNECT_TIMEOUT:-5}" \
    --max-time "${LITELLM_MAX_TIME:-20}" \
    -o "$tmp" -w "%{http_code}" \
    "${auth[@]}" \
    -H "Accept: application/json" \
    "$url" 2>/dev/null || echo "000")
  _LITELLM_READINESS_HTTP="$code"
  _LITELLM_READINESS_BODY="$(cat "$tmp" 2>/dev/null || true)"
  _LITELLM_DB_STATUS="unknown"
  _LITELLM_CACHE_TYPE=""
  _LITELLM_CALLBACKS=""
  if [[ "$code" == "200" ]] && echo "$_LITELLM_READINESS_BODY" | jq -e . >/dev/null 2>&1; then
    _LITELLM_DB_STATUS="$(echo "$_LITELLM_READINESS_BODY" | jq -r '.db // "unknown"' 2>/dev/null)"
    _LITELLM_CACHE_TYPE="$(echo "$_LITELLM_READINESS_BODY" | jq -r '.cache // ""' 2>/dev/null)"
    _LITELLM_CALLBACKS="$(echo "$_LITELLM_READINESS_BODY" | jq -r '[.success_callbacks[]?] | join(",")' 2>/dev/null || echo "")"
  fi
  rm -f "$tmp" 2>/dev/null || true
  _LITELLM_READINESS_CACHED=1
  [[ "$code" == "200" ]]
}

# Convenience predicate. Returns 0 (true) if /health/readiness reports a
# connected spend-tracking database. Triggers a readiness probe on first call.
litellm_db_connected() {
  litellm_readiness >/dev/null 2>&1 || true
  [[ "${_LITELLM_DB_STATUS:-unknown}" == "connected" ]]
}

# Classifies a failed /spend/logs (or other spend-DB-backed) response and
# echoes a descriptive reason for task output. Consults /health/readiness so
# the reason is accurate ("no DB backing" vs "DB connected but request
# timed out / tunnel dropped").
#
# Usage:
#   litellm_classify_spend_failure "$HTTP_CODE" "$BODY_FILE"
litellm_classify_spend_failure() {
  local code="$1"
  local body_file="${2:-}"
  litellm_readiness >/dev/null 2>&1 || true
  local db="${_LITELLM_DB_STATUS:-unknown}"
  if [[ -n "$body_file" ]] && litellm_is_enterprise_gated "$body_file"; then
    printf 'enterprise-gated'
    return 0
  fi
  if [[ "$code" == "000" ]]; then
    if [[ "$db" == "connected" ]]; then
      printf 'transient-tunnel-or-timeout'
    elif [[ "$db" == "disconnected" ]]; then
      printf 'db-not-connected'
    else
      printf 'unknown-readiness-unreachable'
    fi
    return 0
  fi
  if [[ "$code" == "500" || "$code" == "503" ]]; then
    if [[ "$db" == "connected" ]]; then
      printf 'db-connected-endpoint-error'
    else
      printf 'db-not-connected'
    fi
    return 0
  fi
  if [[ "$code" == "404" ]]; then
    printf 'endpoint-not-found'
    return 0
  fi
  if [[ "$code" == "401" || "$code" == "403" ]]; then
    printf 'auth-or-license-denied'
    return 0
  fi
  printf 'http-%s' "$code"
}
