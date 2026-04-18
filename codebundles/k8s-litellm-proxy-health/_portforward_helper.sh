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
  while (( i < max )); do
    if (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; then
      exec 3>&- 3<&- 2>/dev/null || true
      return 0
    fi
    sleep 1
    i=$((i+1))
  done
  return 1
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
  "$kbin" --context "$CONTEXT" -n "$NAMESPACE" port-forward "svc/${LITELLM_SERVICE_NAME}" "${local_port}:${remote_port}" \
    >"$pf_log" 2>&1 &
  LITELLM_PF_PID=$!
  export LITELLM_PF_PID

  trap '_litellm_cleanup_portforward' EXIT INT TERM

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
