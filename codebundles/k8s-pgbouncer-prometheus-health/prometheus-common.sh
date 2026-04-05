#!/usr/bin/env bash
# Shared helpers for Prometheus instant queries (PgBouncer exporter metrics).
# shellcheck disable=SC2034

prometheus_query_url() {
  local u="${PROMETHEUS_URL%/}"
  if [[ "$u" == */api/v1/query ]]; then
    echo "$u"
  elif [[ "$u" == */api/v1 ]]; then
    echo "${u}/query"
  else
    echo "${u}/api/v1/query"
  fi
}

# Build label matcher fragment: {job="...",kubernetes_namespace="..."}
pgbouncer_label_matcher() {
  local inner="${PGBOUNCER_JOB_LABEL}"
  if [ -n "${METRIC_NAMESPACE_FILTER:-}" ]; then
    local nl="${METRIC_NAMESPACE_LABEL:-kubernetes_namespace}"
    inner="${inner},${nl}=\"${METRIC_NAMESPACE_FILTER}\""
  fi
  echo "{${inner}}"
}

# Run instant query; echoes raw JSON from Prometheus API on stdout.
# On transport failure, returns a minimal JSON object so callers can raise issues instead of exiting.
prom_instant_query() {
  local query="$1"
  local url
  url="$(prometheus_query_url)"
  local curl_args=(-sS -G "$url" --data-urlencode "query=${query}")
  if [ -n "${PROMETHEUS_BEARER_TOKEN:-}" ]; then
    curl_args+=(-H "Authorization: Bearer ${PROMETHEUS_BEARER_TOKEN}")
  fi
  local out
  if ! out=$(curl "${curl_args[@]}" 2>/dev/null); then
    echo '{"status":"error","error":"curl_failed","data":null}'
    return 0
  fi
  echo "$out"
}

# Return Prometheus status field from JSON or "error"
prom_status() {
  echo "$1" | jq -r '.status // "error"'
}
