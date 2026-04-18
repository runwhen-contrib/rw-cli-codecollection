#!/usr/bin/env bash
set -uo pipefail
# -----------------------------------------------------------------------------
# Lightweight JSON scores for sli.robot: liveness, readiness, Kubernetes Service.
# Prints EXACTLY one line of JSON to stdout so sli.robot can json.loads it.
# All diagnostics go to stderr.
#
# PROXY_BASE_URL is optional. When unset, kubectl port-forward is used against
# svc/${LITELLM_SERVICE_NAME} on ${LITELLM_HTTP_PORT}.
# -----------------------------------------------------------------------------
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${LITELLM_SERVICE_NAME:?Must set LITELLM_SERVICE_NAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_portforward_helper.sh"
# The port-forward helper echoes its banner to stdout, which would pollute the
# JSON that sli.robot parses. Redirect its stdout to stderr for the SLI path.
ensure_proxy_base_url 1>&2 || true

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

jq -cn --argjson l "$liveness_score" --argjson r "$readiness_score" --argjson k "$k8s_score" \
  '{liveness:$l, readiness:$r, kubernetes_service:$k}'
