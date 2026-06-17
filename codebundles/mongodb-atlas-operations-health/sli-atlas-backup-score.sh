#!/usr/bin/env bash
set -euo pipefail

# SLI dimension: 1 when every in-scope dedicated cluster reports backup enabled.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./atlas-helpers.sh
source "${SCRIPT_DIR}/atlas-helpers.sh"

: "${ATLAS_PROJECT_ID:?}"
if ! atlas_resolve_credentials; then
  jq -n '{score:0,"reason":"no-credentials"}'
  exit 0
fi

atlas_get "groups/${ATLAS_PROJECT_ID}/clusters?itemsPerPage=500"
if [[ "$ATLAS_LAST_HTTP_CODE" != "200" ]]; then
  jq -n --arg c "$ATLAS_LAST_HTTP_CODE" '{score:0,"reason":("http-"+$c)}'
  exit 0
fi

bad=0
checked=0
while IFS= read -r row; do
  [[ -z "$row" ]] && continue
  name="$(echo "$row" | jq -r '.name')"
  cluster_matches_filter "$name" || continue
  ctype="$(echo "$row" | jq -r '.clusterType // ""')"
  if [[ "$ctype" == "REPLICA_SET" || "$ctype" == "SHARDED" || "$ctype" == "GEOSHARDED" ]]; then
    checked=$((checked + 1))
    backup_on="$(echo "$row" | jq -r '(.backupEnabled // false) or (.providerBackupEnabled // false)')"
    if [[ "$backup_on" != "true" ]]; then
      bad=$((bad + 1))
    fi
  fi
done < <(echo "$ATLAS_LAST_BODY" | jq -c '.results[]?')

if [[ "$checked" -eq 0 ]]; then
  jq -n '{score:1,"note":"no-dedicated-clusters-in-scope"}'
elif [[ "$bad" -eq 0 ]]; then
  jq -n '{score:1}'
else
  jq -n --argjson bad "$bad" '{score:0,"clusters_without_backup":$bad}'
fi
