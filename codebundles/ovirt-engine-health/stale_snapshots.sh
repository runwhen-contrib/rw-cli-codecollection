#!/bin/bash
# Find oVirt VM snapshots older than a max-age threshold (arg 1, e.g. 7d / 24h;
# default 7d). The always-present "Active VM" snapshot (snapshot_type=active)
# is excluded. Old snapshots are a common cause of disk bloat and slow merges.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ovirt_auth.sh"

MAX_AGE="${1:-7d}"
SECONDS_BACK=$(ovirt_duration_to_seconds "${MAX_AGE}")
CUTOFF_MS=$(( ($(date +%s) - SECONDS_BACK) * 1000 ))

vms_json=$(ovirt_get "/vms")

stale="[]"
while IFS=$'\t' read -r vid vname; do
    [ -z "${vid}" ] && continue
    snaps=$(ovirt_get "/vms/${vid}/snapshots")
    vm_stale=$(echo "${snaps}" | jq --arg vm "${vname}" --argjson cutoff "${CUTOFF_MS}" '
      [ .snapshot[]?
        | select((.snapshot_type // "") != "active")
        | ((.date // 0) | tostring | (try tonumber catch 0)) as $d
        | select($d > 0 and $d < $cutoff)
        | {
            vm: $vm,
            snapshot_id: .id,
            description: (.description // ""),
            date_ms: $d
          }
      ]' 2>/dev/null)
    [ -z "${vm_stale}" ] && vm_stale="[]"
    stale=$(echo "${stale} ${vm_stale}" | jq -s 'add')
done < <(echo "${vms_json}" | jq -r '.vm[]? | [.id, .name] | @tsv')

echo "{\"max_age\": \"${MAX_AGE}\", \"stale_snapshots\": ${stale}}"
