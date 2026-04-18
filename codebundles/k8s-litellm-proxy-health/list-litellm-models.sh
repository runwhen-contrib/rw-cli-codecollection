#!/usr/bin/env bash
set -euo pipefail
# -----------------------------------------------------------------------------
# Lists models via /v1/models and /v1/model/info (LiteLLM) with optional Bearer.
#
# PROXY_BASE_URL is optional. When unset, kubectl port-forward is used against
# svc/${LITELLM_SERVICE_NAME} on ${LITELLM_HTTP_PORT}.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_portforward_helper.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_master_key_helper.sh"
ensure_proxy_base_url
resolve_master_key

OUTPUT_FILE="${OUTPUT_FILE:-litellm_models_issues.json}"
issues_json='[]'
BASE_URL="${PROXY_BASE_URL%/}"
MAX_TIME="${CURL_MAX_TIME:-25}"

auth_header=()
if [[ -n "${LITELLM_MASTER_KEY:-}" ]]; then
  auth_header=(-H "Authorization: Bearer ${LITELLM_MASTER_KEY}")
  echo "Auth: using LITELLM_MASTER_KEY (Bearer)."
else
  echo "Auth: no master key available; requests will go out unauthenticated."
fi

mf=$(mktemp)
mif=$(mktemp)
mc=$(curl -sS --max-time "$MAX_TIME" -o "$mf" -w "%{http_code}" "${auth_header[@]}" \
  -H "Accept: application/json" "${BASE_URL}/v1/models" 2>/dev/null || echo "000")
models_json=$(cat "$mf" || true)
models_preview=$(printf '%s' "$models_json" | head -c 400 | tr -d '\r' | tr '\n' ' ')
echo "GET ${BASE_URL}/v1/models -> HTTP ${mc}"
[[ -n "$models_preview" ]] && echo "  body: ${models_preview}"

mic=$(curl -sS --max-time "$MAX_TIME" -o "$mif" -w "%{http_code}" "${auth_header[@]}" \
  -H "Accept: application/json" "${BASE_URL}/v1/model/info" 2>/dev/null || echo "000")
mi_json=$(cat "$mif" || true)
mi_preview=$(printf '%s' "$mi_json" | head -c 400 | tr -d '\r' | tr '\n' ' ')
echo "GET ${BASE_URL}/v1/model/info -> HTTP ${mic}"
[[ -n "$mi_preview" ]] && echo "  body: ${mi_preview}"
rm -f "$mf" "$mif"

model_count=0
if [[ "$mc" == "200" ]] && echo "$models_json" | jq -e . >/dev/null 2>&1; then
  model_count=$(echo "$models_json" | jq '[.data[]?] | length' 2>/dev/null || echo 0)
fi

if [[ "$model_count" -eq 0 ]] && [[ "$mic" == "200" ]] && echo "$mi_json" | jq -e . >/dev/null 2>&1; then
  model_count=$(echo "$mi_json" | jq 'if type == "array" then length elif .data then (.data | length) else 1 end' 2>/dev/null || echo 0)
fi

model_names=""
if [[ "$mc" == "200" ]] && echo "$models_json" | jq -e . >/dev/null 2>&1; then
  model_names=$(echo "$models_json" | jq -r '[.data[]?.id] | join(", ")' 2>/dev/null || true)
fi
echo "Parsed: model_count=${model_count}${model_names:+ [${model_names}]}"

if [[ "$mc" == "401" ]] || [[ "$mic" == "401" ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "LiteLLM model listing requires authentication for \`${BASE_URL}\`" \
    --arg details "HTTP 401 from /v1/models or /v1/model/info. Configure litellm_master_key secret if these routes are protected." \
    --argjson severity 2 \
    --arg next_steps "Import the LiteLLM master key as secret litellm_master_key or open read access for listing routes per your security model." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": $severity,
       "next_steps": $next_steps
     }]')
elif [[ "$model_count" -eq 0 ]] && [[ "$mc" == "200" || "$mic" == "200" ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No models registered in LiteLLM proxy \`${BASE_URL}\`" \
    --arg details "Parsed zero models from /v1/models and /v1/model/info responses. models_http=${mc} model_info_http=${mic}" \
    --argjson severity 2 \
    --arg next_steps "Verify config.yaml model_list, secrets for providers, and that the proxy finished loading configuration." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": $severity,
       "next_steps": $next_steps
     }]')
elif [[ "$mc" != "200" && "$mic" != "200" ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Could not list LiteLLM models for \`${BASE_URL}\`" \
    --arg details "GET /v1/models -> HTTP ${mc}; GET /v1/model/info -> HTTP ${mic}" \
    --argjson severity 3 \
    --arg next_steps "Check proxy logs, URL base path, and whether an API prefix or gateway strips /v1 routes." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": $severity,
       "next_steps": $next_steps
     }]')
fi

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "Model listing check complete. Issues written to $OUTPUT_FILE"
cat "$OUTPUT_FILE"
