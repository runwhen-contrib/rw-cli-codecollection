#!/usr/bin/env bash
# SLI dimension: Vercel project reachable via REST API (binary score JSON).
set -uo pipefail

: "${VERCEL_PROJECT_ID:?Must set VERCEL_PROJECT_ID}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vercel-helpers.sh
source "${SCRIPT_DIR}/vercel-helpers.sh"

if [[ -z "$(vercel_token_value)" ]]; then
  echo '{"score":0}'
  exit 0
fi

if vercel_py get-project --project-id "${VERCEL_PROJECT_ID}" --out /dev/null >/dev/null 2>&1; then
  echo '{"score":1}'
else
  echo '{"score":0}'
fi
