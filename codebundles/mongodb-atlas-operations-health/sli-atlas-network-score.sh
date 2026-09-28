#!/usr/bin/env bash
set -euo pipefail

# SLI dimension: 1 when no 0.0.0.0/0 entry and not empty allowlist with public SRV.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./atlas-helpers.sh
source "${SCRIPT_DIR}/atlas-helpers.sh"

: "${ATLAS_PROJECT_ID:?}"
if ! atlas_resolve_credentials; then
  jq -n '{score:0,"reason":"no-credentials"}'
  exit 0
fi

atlas_get "groups/${ATLAS_PROJECT_ID}/accessList?itemsPerPage=500"
if [[ "$ATLAS_LAST_HTTP_CODE" != "200" ]]; then
  jq -n --arg c "$ATLAS_LAST_HTTP_CODE" '{score:0,"reason":("http-"+$c)}'
  exit 0
fi

open_cidr=0
while IFS= read -r row; do
  [[ -z "$row" ]] && continue
  cidr="$(echo "$row" | jq -r '.cidrBlock // empty')"
  ip="$(echo "$row" | jq -r '.ipAddress // empty')"
  target="${cidr:-$ip}"
  [[ "$target" == "0.0.0.0/0" ]] && open_cidr=1
done < <(echo "$ATLAS_LAST_BODY" | jq -c '.results[]?')

count="$(echo "$ATLAS_LAST_BODY" | jq '.results|length')"

atlas_get "groups/${ATLAS_PROJECT_ID}/clusters?itemsPerPage=500"
has_public_srv=0
if [[ "$ATLAS_LAST_HTTP_CODE" == "200" ]]; then
  while IFS= read -r row; do
    name="$(echo "$row" | jq -r '.name')"
    cluster_matches_filter "$name" || continue
    srv="$(echo "$row" | jq -r '.connectionStrings.standardSrv // empty')"
    [[ -n "$srv" ]] && has_public_srv=1
  done < <(echo "$ATLAS_LAST_BODY" | jq -c '.results[]?')
fi

if [[ "$open_cidr" -ne 0 ]]; then
  jq -n '{score:0,"reason":"open-cidr"}'
  exit 0
fi

if [[ "$count" -eq 0 && "$has_public_srv" -eq 1 ]]; then
  jq -n '{score:0,"reason":"empty-list-public-srv"}'
  exit 0
fi

jq -n '{score:1}'
