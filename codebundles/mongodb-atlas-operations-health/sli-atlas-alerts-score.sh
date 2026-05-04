#!/usr/bin/env bash
set -euo pipefail

# SLI dimension: 1 when no OPEN/TRACKING alerts for in-scope clusters (first page only).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./atlas-helpers.sh
source "${SCRIPT_DIR}/atlas-helpers.sh"

: "${ATLAS_PROJECT_ID:?}"
if ! atlas_resolve_credentials; then
  jq -n '{score:0,"reason":"no-credentials"}'
  exit 0
fi

atlas_get "groups/${ATLAS_PROJECT_ID}/alerts?itemsPerPage=100&pageNum=1"
if [[ "$ATLAS_LAST_HTTP_CODE" != "200" ]]; then
  jq -n --arg c "$ATLAS_LAST_HTTP_CODE" '{score:0,"reason":("http-"+$c)}'
  exit 0
fi

open=0
while IFS= read -r row; do
  [[ -z "$row" ]] && continue
  st="$(echo "$row" | jq -r '.status // ""')"
  cname="$(echo "$row" | jq -r '.clusterName // ""')"
  cluster_matches_filter "$cname" || continue
  if [[ "$st" == "OPEN" || "$st" == "TRACKING" ]]; then
    open=$((open + 1))
  fi
done < <(echo "$ATLAS_LAST_BODY" | jq -c '.results[]?')

if [[ "$open" -eq 0 ]]; then
  jq -n '{score:1}'
else
  jq -n --argjson n "$open" '{score:0,"open_tracking":$n}'
fi
