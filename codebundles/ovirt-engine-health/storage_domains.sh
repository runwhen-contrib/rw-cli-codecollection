#!/bin/bash
# Report oVirt storage domain capacity and status. A domain is flagged when its
# external_status is not 'ok', or when its free space falls below the supplied
# percentage threshold (arg 1, default 10).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ovirt_auth.sh"

THRESHOLD="${1:-10}"

sd_json=$(ovirt_get "/storagedomains")

echo "${sd_json}" | jq --argjson threshold "${THRESHOLD}" '
  def free_pct: (.available // 0) as $a | (.used // 0) as $u
    | (if ($a + $u) > 0 then ($a / ($a + $u) * 100) else 100 end);
  {
    threshold_pct: $threshold,
    storage_domains: [ .storage_domain[]? | {
      name: .name,
      id: .id,
      type: (.type // ""),
      external_status: (.external_status // "n/a"),
      available_bytes: (.available // 0),
      used_bytes: (.used // 0),
      free_pct: (free_pct | floor)
    } ],
    problem_domains: [ .storage_domain[]?
      | (free_pct) as $fp
      | select( ((.external_status // "ok") != "ok") or ($fp < $threshold) )
      | {
          name: .name,
          id: .id,
          type: (.type // ""),
          external_status: (.external_status // "n/a"),
          free_pct: ($fp | floor),
          available_bytes: (.available // 0)
        }
    ]
  }'
