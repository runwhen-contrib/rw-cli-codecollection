#!/bin/bash
# List recent critical (error/alert) oVirt engine events within a lookback
# window (arg 1, e.g. 1h / 30m / 1d; default 1h). The engine search query
# narrows to severity above warning; results are then filtered client-side by
# event time so the window is honoured precisely.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ovirt_auth.sh"

LOOKBACK="${1:-1h}"
SECONDS_BACK=$(ovirt_duration_to_seconds "${LOOKBACK}")
CUTOFF_MS=$(( ($(date +%s) - SECONDS_BACK) * 1000 ))

# severity>warning returns error + alert events. max caps the payload size.
events_json=$(ovirt_get "/events?search=severity%3Ewarning&max=200")

echo "${events_json}" | jq --argjson cutoff "${CUTOFF_MS}" --arg lookback "${LOOKBACK}" '
  {
    lookback: $lookback,
    critical_events: [ .event[]?
      | select(((.time // 0) | tostring | (try tonumber catch 0)) >= $cutoff)
      | select((.severity // "") | IN("error","alert"))
      | {
          id: .id,
          severity: .severity,
          time: (.time // ""),
          code: (.code // ""),
          description: (.description // ""),
          host: (.host.name // ""),
          vm: (.vm.name // ""),
          storage_domain: (.storage_domain.name // "")
        }
    ]
  }'
