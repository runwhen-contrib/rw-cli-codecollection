#!/usr/bin/env bash
set -uo pipefail
# -----------------------------------------------------------------------------
# Lightweight JSON scores for sli.robot: API health, replica readiness, and
# storage health. Prints EXACTLY one line of JSON to stdout so sli.robot can
# json.loads it. All diagnostics go to stderr (except the JSON line).
#
# Dimensions:
#   api_health       - 1 when the OpenObserve health endpoint returns HTTP 200
#   replicas_ready   - 1 when the matched OpenObserve workload has all desired
#                      replicas ready (or is scaled to >0); 0 when degraded.
#   storage_healthy  - 1 when storage_metrics is unreported/clean, or when
#                      s3_access_failures stays at/below STORAGE_S3_FAILURE_THRESHOLD.
#
# Required env: CONTEXT, NAMESPACE
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_portforward_helper.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_openobserve_api_common.sh"

KUBERNETES_DISTRIBUTION_BINARY="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
KBIN="$KUBERNETES_DISTRIBUTION_BINARY"
MAX_TIME="${OPENOBSERVE_API_TIMEOUT:-15}"
S3_THRESHOLD="${STORAGE_S3_FAILURE_THRESHOLD:-10}"
ORG="${OPENOBSERVE_ORGANIZATION:-default}"

# -- Dimension: replica readiness -------------------------------------------
replica_score=0
if [[ -n "${OBJECT_NAME:-}" ]]; then
  desired=$("$KBIN" --context "$CONTEXT" -n "$NAMESPACE" get deploy,sts "$OBJECT_NAME" -o json 2>/dev/null \
    | jq -r '[.items[]? | (.spec.replicas // 0)] | max // 0' 2>/dev/null || echo "0")
  ready=$("$KBIN" --context "$CONTEXT" -n "$NAMESPACE" get deploy,sts "$OBJECT_NAME" -o json 2>/dev/null \
    | jq -r '[.items[]? | (.status.readyReplicas // 0)] | add // 0' 2>/dev/null || echo "0")
  if [[ "${desired:-0}" -eq 0 ]]; then
    replica_score=0
  elif [[ "${ready:-0}" -ge "${desired:-0}" ]]; then
    replica_score=1
  else
    replica_score=0
  fi
else
  # No OBJECT_NAME: sum across all openobserve-named workloads.
  desired=0; ready=0
  while IFS= read -r wl; do
    [[ -z "$wl" ]] && continue
    dd=$(echo "$wl" | jq -r '.spec.replicas // 0')
    rr=$(echo "$wl" | jq -r '.status.readyReplicas // 0')
    desired=$((desired + dd))
    ready=$((ready + rr))
  done < <("$KBIN" --context "$CONTEXT" -n "$NAMESPACE" get deploy,sts -o json 2>/dev/null \
    | jq -c '.items[] | select(.metadata.name | test("openobserve"; "i"))' 2>/dev/null || true)
  replica_score=0
  if [[ "$desired" -eq 0 ]]; then
    replica_score=0
  elif [[ "$ready" -ge "$desired" ]]; then
    replica_score=1
  fi
fi

# -- Dimension: API health ----------------------------------------------------
api_score=0
if ensure_openobserve_base_url 1>&2; then
  load_openobserve_credentials 1>&2 || true
  BASE="${OPENOBSERVE_BASE_URL%/}"
  for path in "/api/${ORG}/health" "/healthz" "/health"; do
    code=$(curl -sS --max-time "$MAX_TIME" -o /dev/null -w "%{http_code}" "${BASE}${path}" 2>/dev/null || echo "000")
    if [[ "$code" == "200" ]]; then
      api_score=1
      break
    fi
  done
fi

# -- Dimension: storage health ------------------------------------------------
storage_score=1
if [[ "$api_score" -eq 1 ]]; then
  for path in "/api/${ORG}/storage_metrics" "/api/${ORG}/internal_metrics"; do
    out=$(openobserve_api_get "$path")
    code="${out%%$'\t'*}"
    body="${out#*$'\t'}"
    if [[ "$code" == "200" ]]; then
      s3f=$(echo "$body" | jq -r '(.s3_access_failures // .s3_failures // .data.s3_access_failures // .data.s3_failures // 0)' 2>/dev/null | awk '{print int($1)}')
      s3f="${s3f:-0}"
      if [[ "$s3f" -gt "$S3_THRESHOLD" ]]; then
        storage_score=0
      fi
      break
    fi
  done
fi

jq -cn \
  --argjson a "$api_score" \
  --argjson r "$replica_score" \
  --argjson s "$storage_score" \
  '{api_health: $a, replicas_ready: $r, storage_healthy: $s}'