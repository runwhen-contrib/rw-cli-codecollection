#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Shared helper to ensure PROXY_BASE_URL is reachable.
#
# Behavior:
#   - If PROXY_BASE_URL is already set and non-empty, use it as-is.
#   - Otherwise, start a kubectl port-forward to the LiteLLM Service and
#     export PROXY_BASE_URL=http://127.0.0.1:<local_port>. A trap is
#     registered to stop the port-forward on EXIT.
#
# Required when starting a port-forward:
#   CONTEXT, NAMESPACE, LITELLM_SERVICE_NAME
# Optional:
#   LITELLM_HTTP_PORT           (default: 4000)
#   LITELLM_LOCAL_PORT          (default: pick an ephemeral free port)
#   KUBERNETES_DISTRIBUTION_BINARY  (default: kubectl)
#   LITELLM_PF_WAIT_SECS        (default: 10 — max seconds to wait for pf)
#
# Exports:
#   PROXY_BASE_URL
#   LITELLM_PF_PID   (pid of the background port-forward, if started)
# -----------------------------------------------------------------------------

_litellm_pick_free_port() {
  python3 - <<'PY' 2>/dev/null || echo ""
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

_litellm_wait_for_port() {
  local host="$1" port="$2" max="${3:-10}"
  local i=0
  # Phase 1: TCP bind. kubectl port-forward accepts on localhost very quickly,
  # but that doesn't mean the tunnel to the pod is ready.
  while (( i < max )); do
    if (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; then
      exec 3>&- 3<&- 2>/dev/null || true
      break
    fi
    sleep 1
    i=$((i+1))
  done
  if (( i >= max )); then
    return 1
  fi

  # Phase 2: real HTTP round-trip. Loop until curl gets any non-000 HTTP code
  # back. This is what catches the "socket accepted, tunnel not wired yet"
  # window where curl otherwise sees ECONNRESET immediately.
  if command -v curl >/dev/null 2>&1; then
    local j=0
    while (( j < max )); do
      local code
      code=$(curl -sS --connect-timeout 3 --max-time 5 \
        -o /dev/null -w "%{http_code}" \
        "http://${host}:${port}/health/liveliness" 2>/dev/null || echo "000")
      if [[ "$code" != "000" ]]; then
        return 0
      fi
      sleep 1
      j=$((j+1))
    done
    return 1
  fi
  return 0
}

ensure_proxy_base_url() {
  if [[ -n "${PROXY_BASE_URL:-}" ]]; then
    export PROXY_BASE_URL
    return 0
  fi

  : "${CONTEXT:?PROXY_BASE_URL empty and CONTEXT not set — cannot start port-forward}"
  : "${NAMESPACE:?PROXY_BASE_URL empty and NAMESPACE not set — cannot start port-forward}"
  : "${LITELLM_SERVICE_NAME:?PROXY_BASE_URL empty and LITELLM_SERVICE_NAME not set — cannot start port-forward}"

  local kbin="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
  local remote_port="${LITELLM_HTTP_PORT:-4000}"
  local local_port="${LITELLM_LOCAL_PORT:-}"
  local wait_secs="${LITELLM_PF_WAIT_SECS:-10}"

  if ! command -v "$kbin" >/dev/null 2>&1; then
    echo "ERROR: PROXY_BASE_URL not set and ${kbin} not found on PATH; cannot establish port-forward." >&2
    return 1
  fi

  if [[ -z "$local_port" ]]; then
    local_port="$(_litellm_pick_free_port)"
    if [[ -z "$local_port" ]]; then
      local_port="$remote_port"
    fi
  fi

  echo "PROXY_BASE_URL not provided; starting kubectl port-forward to svc/${LITELLM_SERVICE_NAME} ${local_port}:${remote_port} in ns ${NAMESPACE} (context ${CONTEXT})."

  local pf_log
  pf_log="$(mktemp)"
  # CRITICAL: redirect stdin from /dev/null AND explicitly close fd 3 in the
  # child. Without this, kubectl port-forward inherits fd 3 (a dup of the
  # script's original stdout, opened by litellm_init_runtime so diagnostics
  # can survive $() capture). That inherited fd keeps the parent subprocess's
  # stdout pipe open even after the main bash script exits, which causes
  # Python's subprocess.communicate() to block up to its timeout (180s) even
  # though the script itself finished in seconds.
  "$kbin" --context "$CONTEXT" -n "$NAMESPACE" port-forward "svc/${LITELLM_SERVICE_NAME}" "${local_port}:${remote_port}" \
    </dev/null >"$pf_log" 2>&1 3>&- &
  LITELLM_PF_PID=$!
  # Detach from shell job table so the parent bash can exit without waiting.
  disown "$LITELLM_PF_PID" 2>/dev/null || true
  export LITELLM_PF_PID

  # Prefer the shared cleanup registry installed by litellm_init_runtime so
  # a per-script `trap '...' EXIT` (typical for a $TMP rm) doesn't clobber
  # port-forward teardown. Fall back to an exclusive trap if the registry
  # function isn't loaded (e.g. someone sources this helper directly).
  if declare -F litellm_register_cleanup >/dev/null 2>&1; then
    litellm_register_cleanup '_litellm_cleanup_portforward'
  else
    trap '_litellm_cleanup_portforward' EXIT INT TERM
  fi

  if ! _litellm_wait_for_port "127.0.0.1" "$local_port" "$wait_secs"; then
    echo "ERROR: kubectl port-forward did not become ready within ${wait_secs}s." >&2
    echo "port-forward log (truncated):" >&2
    head -c 2000 "$pf_log" >&2 || true
    rm -f "$pf_log" || true
    _litellm_cleanup_portforward
    return 1
  fi

  rm -f "$pf_log" || true

  export PROXY_BASE_URL="http://127.0.0.1:${local_port}"
  echo "PROXY_BASE_URL=${PROXY_BASE_URL} (via port-forward pid ${LITELLM_PF_PID})"
  return 0
}

_litellm_cleanup_portforward() {
  if [[ -n "${LITELLM_PF_PID:-}" ]] && kill -0 "$LITELLM_PF_PID" 2>/dev/null; then
    kill "$LITELLM_PF_PID" 2>/dev/null || true
    wait "$LITELLM_PF_PID" 2>/dev/null || true
  fi
  LITELLM_PF_PID=""
}
