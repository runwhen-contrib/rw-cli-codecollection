#!/usr/bin/env bash
set -uo pipefail
# -----------------------------------------------------------------------------
# Runs once from Suite Setup. Resolves the OpenObserve admin credentials using
# every strategy available (RW secret, explicit Secret name, Pod env inference,
# optional kubectl exec fallback) and caches them to ./.openobserve_credentials
# so the per-task scripts can pick them up via _openobserve_credentials_helper.sh.
#
# The cache file and this script never print the credential values themselves -
# only the origin (secret / pod / exec) is logged.
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_openobserve_credentials_helper.sh"

CACHE_FILE="${OPENOBSERVE_CREDENTIALS_CACHE_FILE:-./.openobserve_credentials}"
export OPENOBSERVE_CREDENTIALS_CACHE_FILE="$CACHE_FILE"

rm -f "$CACHE_FILE" 2>/dev/null || true

echo "--- OpenObserve credential resolution ---"
echo "CONTEXT=${CONTEXT:-<unset>} NAMESPACE=${NAMESPACE:-<unset>} OBJECT_NAME=${OBJECT_NAME:-<unset>} OPENOBSERVE_SERVICE_NAME=${OPENOBSERVE_SERVICE_NAME:-<unset>}"
echo "OPENOBSERVE_CREDENTIAL_SECRET_NAME=${OPENOBSERVE_CREDENTIAL_SECRET_NAME:-<unset>} OPENOBSERVE_CREDENTIAL_USER_KEY=${OPENOBSERVE_CREDENTIAL_USER_KEY:-<unset>} OPENOBSERVE_CREDENTIAL_PASSWORD_KEY=${OPENOBSERVE_CREDENTIAL_PASSWORD_KEY:-<unset>} OPENOBSERVE_ALLOW_EXEC=${OPENOBSERVE_ALLOW_EXEC:-false}"

resolve_and_cache_openobserve_credentials

if [[ -s "$CACHE_FILE" ]]; then
  echo "Result: credentials resolved (cache written to ${CACHE_FILE})."
  exit 0
fi

echo "Result: credentials NOT RESOLVED. API tasks will likely return HTTP 401."
echo "Provide them via the openobserve_credentials secret, set OPENOBSERVE_CREDENTIAL_SECRET_NAME, ensure the workload exposes ROOT_USER_EMAIL/ROOT_USER_PASSWORD (or ZO_ROOT_USER_*) via a readable Secret, or set OPENOBSERVE_ALLOW_EXEC=true to allow the exec fallback."
exit 0