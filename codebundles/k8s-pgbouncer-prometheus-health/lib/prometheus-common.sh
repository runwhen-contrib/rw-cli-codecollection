#!/usr/bin/env bash
# Shared helpers for Prometheus HTTP API queries (instant + range).
# shellcheck disable=SC2034

prometheus_api_base() {
  local u="${PROMETHEUS_URL:?Must set PROMETHEUS_URL}"
  u="${u%/}"
  if [[ "$u" != *"/api/v1" ]]; then
    u="${u}/api/v1"
  fi
  printf '%s' "$u"
}

metric_label_filter() {
  local j="${PGBOUNCER_JOB_LABEL:?Must set PGBOUNCER_JOB_LABEL}"
  local ns="${METRIC_NAMESPACE_FILTER:-}"
  if [ -n "$ns" ]; then
    printf '%s,%s' "$j" "$ns"
  else
    printf '%s' "$j"
  fi
}

wrap_metric() {
  local metric="$1"
  printf '%s{%s}' "$metric" "$(metric_label_filter)"
}

prometheus_instant_query() {
  local query="$1"
  local base url
  base="$(prometheus_api_base)"
  url="${base}/query"
  if [ -n "${PROMETHEUS_BEARER_TOKEN:-}" ]; then
    curl -sS -G --data-urlencode "query=${query}" -H "Authorization: Bearer ${PROMETHEUS_BEARER_TOKEN}" "$url"
  else
    curl -sS -G --data-urlencode "query=${query}" "$url"
  fi
}

prometheus_range_query() {
  local query="$1"
  local start="$2"
  local end="$3"
  local step="${4:-30s}"
  local base url
  base="$(prometheus_api_base)"
  url="${base}/query_range"
  if [ -n "${PROMETHEUS_BEARER_TOKEN:-}" ]; then
    curl -sS -G \
      --data-urlencode "query=${query}" \
      --data-urlencode "start=${start}" \
      --data-urlencode "end=${end}" \
      --data-urlencode "step=${step}" \
      -H "Authorization: Bearer ${PROMETHEUS_BEARER_TOKEN}" \
      "$url"
  else
    curl -sS -G \
      --data-urlencode "query=${query}" \
      --data-urlencode "start=${start}" \
      --data-urlencode "end=${end}" \
      --data-urlencode "step=${step}" \
      "$url"
  fi
}

prometheus_query_status_ok() {
  local json="$1"
  local st
  st=$(echo "$json" | jq -r '.status // "error"')
  if [ "$st" = "success" ]; then
    return 0
  fi
  return 1
}

kubectl_bin() {
  printf '%s' "${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
}

kubectl_context_args() {
  if [ -n "${CONTEXT:-}" ]; then
    printf '%s %s' "--context" "${CONTEXT}"
  fi
}
