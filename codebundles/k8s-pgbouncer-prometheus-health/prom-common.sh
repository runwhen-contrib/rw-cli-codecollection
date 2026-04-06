#!/usr/bin/env bash
# Shared helpers for Prometheus instant/range queries (sourced by task scripts).
# shellcheck shell=bash

# If RunWhen passes a file path for the bearer token, read the secret text.
prom_maybe_read_token_file() {
  if [[ -n "${PROMETHEUS_BEARER_TOKEN:-}" && -f "${PROMETHEUS_BEARER_TOKEN}" ]]; then
    PROMETHEUS_BEARER_TOKEN=$(tr -d '\n\r' < "${PROMETHEUS_BEARER_TOKEN}")
    export PROMETHEUS_BEARER_TOKEN
  fi
}

prom_normalize_base_url() {
  local u="${PROMETHEUS_URL:?Must set PROMETHEUS_URL}"
  u="${u%/}"
  if [[ ! "$u" =~ /api/v1$ ]]; then
    u="${u}/api/v1"
  fi
  printf '%s' "$u"
}

# Inner label matchers for PromQL (no outer braces), e.g. job="pgbouncer-exporter"
prom_label_inner() {
  local inner="${PGBOUNCER_JOB_LABEL:?Must set PGBOUNCER_JOB_LABEL}"
  if [[ -n "${METRIC_NAMESPACE_FILTER:-}" ]]; then
    inner="${inner},namespace=\"${METRIC_NAMESPACE_FILTER}\""
  fi
  printf '%s' "$inner"
}

prom_instant_query() {
  prom_maybe_read_token_file
  local query="$1"
  local base url
  base="$(prom_normalize_base_url)"
  url="${base}/query"
  if [[ -n "${PROMETHEUS_BEARER_TOKEN:-}" ]]; then
    curl -sS -X POST "$url" \
      -H "Authorization: Bearer ${PROMETHEUS_BEARER_TOKEN}" \
      --data-urlencode "query=${query}"
  else
    curl -sS -X POST "$url" --data-urlencode "query=${query}"
  fi
}

prom_range_query() {
  prom_maybe_read_token_file
  local query="$1"
  local start="$2"
  local end="$3"
  local step="${4:-60s}"
  local base url
  base="$(prom_normalize_base_url)"
  url="${base}/query_range"
  if [[ -n "${PROMETHEUS_BEARER_TOKEN:-}" ]]; then
    curl -sS -X POST "$url" \
      -H "Authorization: Bearer ${PROMETHEUS_BEARER_TOKEN}" \
      --data-urlencode "query=${query}" \
      --data-urlencode "start=${start}" \
      --data-urlencode "end=${end}" \
      --data-urlencode "step=${step}"
  else
    curl -sS -X POST "$url" \
      --data-urlencode "query=${query}" \
      --data-urlencode "start=${start}" \
      --data-urlencode "end=${end}" \
      --data-urlencode "step=${step}"
  fi
}

prom_check_api() {
  local resp="$1"
  local status
  status=$(echo "$resp" | jq -r '.status // "error"')
  if [[ "$status" != "success" ]]; then
    echo "$resp" | jq -r '.error // .errorType // "unknown error"' 2>/dev/null || echo "Prometheus query failed"
    return 1
  fi
  return 0
}
