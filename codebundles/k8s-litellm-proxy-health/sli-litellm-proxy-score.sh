#!/usr/bin/env bash
set -uo pipefail
set -x
# -----------------------------------------------------------------------------
# Lightweight JSON scores for sli.robot: liveness, readiness, Kubernetes Service.
# Prints one line of JSON to stdout.
# -----------------------------------------------------------------------------
: "${PROXY_BASE_URL:?Must set PROXY_BASE_URL}"
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${LITELLM_SERVICE_NAME:?Must set LITELLM_SERVICE_NAME}"

BASE_URL="${PROXY_BASE_URL%/}"
MAX_TIME="${CURL_MAX_TIME:-15}"
KBIN="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"

liveness_score=0
for path in "/health/liveliness" "/health/live"; do
  code=$(curl -sS --max-time "$MAX_TIME" -o /dev/null -w "%{http_code}" "${BASE_URL}${path}" 2>/dev/null || echo "000")
  if [[ "$code" == "200" ]]; then
    liveness_score=1
    break
  fi
done

readiness_score=0
tmpf=$(mktemp)
rc=$(curl -sS --max-time "$MAX_TIME" -o "$tmpf" -w "%{http_code}" "${BASE_URL}/health/readiness" 2>/dev/null || echo "000")
rbody=$(cat "$tmpf" || true)
rm -f "$tmpf"

if [[ "$rc" == "200" ]] && echo "$rbody" | jq -e . >/dev/null 2>&1; then
  if echo "$rbody" | jq -e '.db == "Not connected"' >/dev/null 2>&1; then
    readiness_score=0
  else
    readiness_score=1
  fi
fi

k8s_score=0
if command -v "$KBIN" &>/dev/null; then
  if "$KBIN" get svc "$LITELLM_SERVICE_NAME" -n "$NAMESPACE" --context "$CONTEXT" --request-timeout=8s &>/dev/null; then
    k8s_score=1
  fi
fi

jq -n --argjson l "$liveness_score" --argjson r "$readiness_score" --argjson k "$k8s_score" \
  '{liveness:$l, readiness:$r, kubernetes_service:$k}'
