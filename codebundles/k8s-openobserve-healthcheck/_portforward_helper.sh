#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Shared helper to ensure OPENOBSERVE_BASE_URL is reachable.
#
# Behavior:
#   - If OPENOBSERVE_BASE_URL is already set and non-empty, use it as-is.
#   - Otherwise, auto-discover the OpenObserve Service (name containing
#     "openobserve" in NAMESPACE) and start a kubectl port-forward to
#     svc/${OPENOBSERVE_SERVICE_NAME} on ${OPENOBSERVE_HTTP_PORT}. A trap is
#     registered to stop the port-forward on EXIT.
#
# Required when starting a port-forward:
#   CONTEXT, NAMESPACE
# Optional:
#   OPENOBSERVE_SERVICE_NAME       (default: auto-discovered from the namespace)
#   OPENOBSERVE_HTTP_PORT          (default: 5080)
#   OPENOBSERVE_LOCAL_PORT         (default: pick an ephemeral free port)
#   KUBERNETES_DISTRIBUTION_BINARY (default: kubectl)
#   OPENOBSERVE_PF_WAIT_SECS       (default: 15 - max seconds to wait for pf)
#
# Exports:
#   OPENOBSERVE_BASE_URL
#   OPENOBSERVE_SERVICE_NAME
#   OPENOBSERVE_PF_PID   (pid of the background port-forward, if started)
# -----------------------------------------------------------------------------

_openobserve_pick_free_port() {
  python3 - <<'PY' 2>/dev/null || echo ""
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

_openobserve_wait_for_port() {
  local host="$1" port="$2" max="${3:-15}"
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

_openobserve_discover_service() {
  # Find a Service whose name contains "openobserve", preferring one that
  # exposes OPENOBSERVE_HTTP_PORT. Emits the best candidate or nothing.
  local kbin="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
  local ctx="${CONTEXT:-}"
  local ns="${NAMESPACE:-}"
  local http_port="${OPENOBSERVE_HTTP_PORT:-5080}"
  local svc=""
  svc=$("$kbin" --context "$ctx" -n "$ns" get services -o json 2>/dev/null \
      | jq -r --arg port "$http_port" '
          ([.items[] | select((.metadata.name | test("openobserve"; "i")) and ([.spec.ports[].port | tostring] | index($port)))] | sort_by(.metadata.creationTimestamp) | reverse | .[0].metadata.name) // empty
        ' 2>/dev/null || true)
  if [[ -z "$svc" ]]; then
    svc=$("$kbin" --context "$ctx" -n "$ns" get services -o json 2>/dev/null \
        | jq -r '[.items[] | select(.metadata.name | test("openobserve"; "i"))][0].metadata.name // empty' 2>/dev/null || true)
  fi
  if [[ -n "$svc" ]]; then
    echo "$svc"
    return 0
  fi
  return 1
}

ensure_openobserve_base_url() {
  if [[ -n "${OPENOBSERVE_BASE_URL:-}" ]]; then
    export OPENOBSERVE_BASE_URL
    return 0
  fi

  : "${CONTEXT:?OPENOBSERVE_BASE_URL empty and CONTEXT not set - cannot start port-forward}"
  : "${NAMESPACE:?OPENOBSERVE_BASE_URL empty and NAMESPACE not set - cannot start port-forward}"

  local kbin="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
  local remote_port="${OPENOBSERVE_HTTP_PORT:-5080}"
  local local_port="${OPENOBSERVE_LOCAL_PORT:-}"
  local wait_secs="${OPENOBSERVE_PF_WAIT_SECS:-15}"

  if ! command -v "$kbin" >/dev/null 2>&1; then
    echo "WARN: OPENOBSERVE_BASE_URL not set and ${kbin} not found on PATH; cannot establish port-forward." >&2
    return 1
  fi

  local svc="${OPENOBSERVE_SERVICE_NAME:-}"
  if [[ -z "$svc" ]]; then
    svc=$(_openobserve_discover_service) || true
    if [[ -n "$svc" ]]; then
      export OPENOBSERVE_SERVICE_NAME="$svc"
      echo "Auto-discovered OpenObserve Service ${svc} in namespace ${NAMESPACE}."
    else
      echo "WARN: No Service whose name contains 'openobserve' found in namespace ${NAMESPACE}; cannot port-forward." >&2
      return 1
    fi
  fi

  if [[ -z "$local_port" ]]; then
    local_port="$(_openobserve_pick_free_port)"
    if [[ -z "$local_port" ]]; then
      local_port="$remote_port"
    fi
  fi

  echo "OPENOBSERVE_BASE_URL not provided; starting kubectl port-forward to svc/${OPENOBSERVE_SERVICE_NAME} ${local_port}:${remote_port} in ns ${NAMESPACE} (context ${CONTEXT})."

  local pf_log
  pf_log="$(mktemp)"
  "$kbin" --context "$CONTEXT" -n "$NAMESPACE" port-forward "svc/${OPENOBSERVE_SERVICE_NAME}" "${local_port}:${remote_port}" \
    >"$pf_log" 2>&1 &
  OPENOBSERVE_PF_PID=$!
  export OPENOBSERVE_PF_PID

  trap '_openobserve_cleanup_portforward' EXIT INT TERM

  if ! _openobserve_wait_for_port "127.0.0.1" "$local_port" "$wait_secs"; then
    echo "ERROR: kubectl port-forward did not become ready within ${wait_secs}s." >&2
    echo "port-forward log (truncated):" >&2
    head -c 2000 "$pf_log" >&2 || true
    rm -f "$pf_log" || true
    _openobserve_cleanup_portforward
    return 1
  fi

  rm -f "$pf_log" || true

  export OPENOBSERVE_BASE_URL="http://127.0.0.1:${local_port}"
  echo "OPENOBSERVE_BASE_URL=${OPENOBSERVE_BASE_URL} (via port-forward pid ${OPENOBSERVE_PF_PID})"
  return 0
}

_openobserve_cleanup_portforward() {
  if [[ -n "${OPENOBSERVE_PF_PID:-}" ]] && kill -0 "$OPENOBSERVE_PF_PID" 2>/dev/null; then
    kill "$OPENOBSERVE_PF_PID" 2>/dev/null || true
    wait "$OPENOBSERVE_PF_PID" 2>/dev/null || true
  fi
  OPENOBSERVE_PF_PID=""
}