#!/usr/bin/env bash
set -uo pipefail
# -----------------------------------------------------------------------------
# Runs once from Suite Setup. Resolves the LiteLLM master key using every
# strategy available (env, RW secret, explicit Secret name, Pod env inference,
# kubectl exec fallback, Secret name-pattern search) and caches it to
# ./.litellm_master_key so the per-task scripts can pick it up via
# _master_key_helper.sh's cache fast path.
#
# The cache file and this script never print the key value itself — only the
# origin (env / pod / secret name+key) is logged.
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_master_key_helper.sh"

CACHE_FILE="${LITELLM_MASTER_KEY_CACHE_FILE:-./.litellm_master_key}"
export LITELLM_MASTER_KEY_CACHE_FILE="$CACHE_FILE"

# Clear any stale cache so resolve_master_key re-derives each run.
rm -f "$CACHE_FILE" 2>/dev/null || true

echo "--- LiteLLM master key resolution ---"
echo "CONTEXT=${CONTEXT:-<unset>} NAMESPACE=${NAMESPACE:-<unset>} LITELLM_SERVICE_NAME=${LITELLM_SERVICE_NAME:-<unset>}"
echo "LITELLM_MASTER_KEY_SECRET_NAME=${LITELLM_MASTER_KEY_SECRET_NAME:-<unset>} LITELLM_MASTER_KEY_SECRET_KEY=${LITELLM_MASTER_KEY_SECRET_KEY:-<unset>}"
echo "LITELLM_MASTER_KEY_INFER_FROM_POD=${LITELLM_MASTER_KEY_INFER_FROM_POD:-true} LITELLM_MASTER_KEY_EXEC_FALLBACK=${LITELLM_MASTER_KEY_EXEC_FALLBACK:-true} LITELLM_MASTER_KEY_SECRET_PATTERN=${LITELLM_MASTER_KEY_SECRET_PATTERN:-litellm}"

resolve_and_cache_master_key

if [[ -s "$CACHE_FILE" ]]; then
  echo "Result: resolved (cache written to ${CACHE_FILE})."
  exit 0
fi

echo "Result: NOT RESOLVED. Tasks that require the master key will likely return HTTP 401."
echo "Provide it via the litellm_master_key secret, LITELLM_MASTER_KEY_SECRET_NAME, ensure the LiteLLM Pod exposes LITELLM_MASTER_KEY via a readable Secret, or grant exec so the fallback can read the env var from the running container."
exit 0
