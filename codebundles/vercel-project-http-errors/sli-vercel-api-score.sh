#!/usr/bin/env bash
# SLI dimension: Vercel project reachable via REST API (binary score JSON).
set -euo pipefail
set -x

: "${VERCEL_PROJECT_ID:?Must set VERCEL_PROJECT_ID}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vercel-http-lib.sh
source "${SCRIPT_DIR}/vercel-http-lib.sh"

if ! auth="$(vercel_auth_header)"; then
  echo '{"score":0}'
  exit 0
fi

url="${VERCEL_API}/v9/projects/${VERCEL_PROJECT_ID}"
tq="$(vercel_team_qs)"
[[ -n "$tq" ]] && url="${url}?${tq}"

http=$(curl -sS --max-time 25 -w '%{http_code}' -o /tmp/vprj.$$ -H "$auth" "$url") || http="000"
rm -f /tmp/vprj.$$
if [[ "$http" == "200" ]]; then
  echo '{"score":1}'
else
  echo '{"score":0}'
fi
