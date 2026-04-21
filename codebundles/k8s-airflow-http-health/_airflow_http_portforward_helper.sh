#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Shared helper: ensure PROXY_BASE_URL is reachable for Airflow HTTP checks.
#
# If PROXY_BASE_URL is non-empty, use it as-is.
# Otherwise start kubectl port-forward to svc/${AIRFLOW_WEBSERVER_SERVICE_NAME}
# and export PROXY_BASE_URL=http://127.0.0.1:<local_port>.
#
# Required for port-forward:
#   CONTEXT, NAMESPACE, AIRFLOW_WEBSERVER_SERVICE_NAME
# Optional:
#   AIRFLOW_HTTP_PORT           (default: 8080)
#   AIRFLOW_LOCAL_PORT          (ephemeral if unset)
#   KUBERNETES_DISTRIBUTION_BINARY  (default: kubectl)
#   AIRFLOW_PF_WAIT_SECS        (default: 15)
#
# Exports:
#   PROXY_BASE_URL
#   AIRFLOW_PF_PID
# -----------------------------------------------------------------------------

_airflow_pick_free_port() {
  python3 - <<'PY' 2>/dev/null || echo ""
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

_airflow_wait_for_port() {
  local host="$1" port="$2" max="${3:-15}"
  local i=0
  while (( i < max )); do
    if (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; then
      exec 3>&- 3<&- 2>/dev/null || true
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

ensure_airflow_proxy_base_url() {
  if [[ -n "${PROXY_BASE_URL:-}" ]]; then
    export PROXY_BASE_URL
    return 0
  fi

  : "${CONTEXT:?PROXY_BASE_URL empty and CONTEXT not set — cannot start port-forward}"
  : "${NAMESPACE:?PROXY_BASE_URL empty and NAMESPACE not set — cannot start port-forward}"
  : "${AIRFLOW_WEBSERVER_SERVICE_NAME:?PROXY_BASE_URL empty and AIRFLOW_WEBSERVER_SERVICE_NAME not set — cannot start port-forward}"

  local kbin="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
  local remote_port="${AIRFLOW_HTTP_PORT:-8080}"
  local local_port="${AIRFLOW_LOCAL_PORT:-}"
  local wait_secs="${AIRFLOW_PF_WAIT_SECS:-15}"

  if ! command -v "$kbin" >/dev/null 2>&1; then
    echo "ERROR: PROXY_BASE_URL not set and ${kbin} not found on PATH; cannot establish port-forward." >&2
    return 1
  fi

  if [[ -z "$local_port" ]]; then
    local_port="$(_airflow_pick_free_port)"
    if [[ -z "$local_port" ]]; then
      local_port="$remote_port"
    fi
  fi

  echo "PROXY_BASE_URL not provided; starting ${kbin} port-forward to svc/${AIRFLOW_WEBSERVER_SERVICE_NAME} ${local_port}:${remote_port} in ns ${NAMESPACE} (context ${CONTEXT})."

  local pf_log
  pf_log="$(mktemp)"
  "$kbin" --context "$CONTEXT" -n "$NAMESPACE" port-forward "svc/${AIRFLOW_WEBSERVER_SERVICE_NAME}" "${local_port}:${remote_port}" \
    >"$pf_log" 2>&1 &
  AIRFLOW_PF_PID=$!
  export AIRFLOW_PF_PID

  trap '_airflow_cleanup_portforward' EXIT INT TERM

  if ! _airflow_wait_for_port "127.0.0.1" "$local_port" "$wait_secs"; then
    echo "ERROR: kubectl port-forward did not become ready within ${wait_secs}s." >&2
    echo "port-forward log (truncated):" >&2
    head -c 2000 "$pf_log" >&2 || true
    rm -f "$pf_log" || true
    _airflow_cleanup_portforward
    return 1
  fi

  rm -f "$pf_log" || true

  export PROXY_BASE_URL="http://127.0.0.1:${local_port}"
  echo "PROXY_BASE_URL=${PROXY_BASE_URL} (via port-forward pid ${AIRFLOW_PF_PID})"
  return 0
}

_airflow_cleanup_portforward() {
  if [[ -n "${AIRFLOW_PF_PID:-}" ]] && kill -0 "$AIRFLOW_PF_PID" 2>/dev/null; then
    kill "$AIRFLOW_PF_PID" 2>/dev/null || true
    wait "$AIRFLOW_PF_PID" 2>/dev/null || true
  fi
  AIRFLOW_PF_PID=""
}
