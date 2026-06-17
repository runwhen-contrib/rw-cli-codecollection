#!/usr/bin/env bash
set -euo pipefail
# Lightweight SLI: project + deployment checks and bounded 404 share sample.
# Prints a single JSON object on stdout (no trace noise).

: "${VERCEL_TEAM_ID:?Must set VERCEL_TEAM_ID}"
: "${VERCEL_PROJECT:?Must set VERCEL_PROJECT}"

LOOKBACK_MINUTES="${LOOKBACK_MINUTES:-60}"
NOT_FOUND_SPIKE_THRESHOLD_PCT="${NOT_FOUND_SPIKE_THRESHOLD_PCT:-15}"
SPIKE_MIN_SAMPLE="${SPIKE_MIN_SAMPLE:-40}"
LOG_SAMPLE_MAX_LINES="${LOG_SAMPLE_MAX_LINES:-3000}"
LOG_FETCH_MAX_SECONDS="${LOG_FETCH_MAX_SECONDS:-20}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_vercel_common.sh"

proj_ok=0
dep_ok=0
ratio_ok=1

if ! vercel_resolve_token; then
  jq -n --argjson p 0 --argjson d 0 --argjson r 0 \
    '{health: 0, project_ok: 0, deployment_ok: 0, ratio_ok: 0, details: "missing token"}'
  exit 0
fi

if vercel_resolve_project_id 2>/dev/null; then
  proj_ok=1
fi

if [ "$proj_ok" -eq 1 ] && vercel_resolve_production_deployment 2>/dev/null; then
  dep_ok=1
fi

if [ "$proj_ok" -eq 0 ] || [ "$dep_ok" -eq 0 ]; then
  h=$(jq -n --argjson p "$proj_ok" --argjson d "$dep_ok" --argjson r 0 \
    '($p + $d) / 2')
  jq -n --argjson p "$proj_ok" --argjson d "$dep_ok" --argjson h "$h" \
    --arg det "project or deployment unresolved" \
    '{health: $h, project_ok: $p, deployment_ok: $d, ratio_ok: 0, details: $det}'
  exit 0
fi

raw="$(mktemp)"
norm="$(mktemp)"
vercel_fetch_runtime_logs_file "$raw"
vercel_normalize_ndjson "$raw" "$norm"
rm -f "$raw"

now_ms="$(python3 -c "import time; print(int(time.time()*1000))")"
cutoff_ms=$((now_ms - LOOKBACK_MINUTES * 60 * 1000))

stats="$(jq -s --argjson cutoff_ms "$cutoff_ms" \
  'map(select(.source != "delimiter"))
   | map(select(.timestampInMs >= $cutoff_ms))
   | map(select(.requestPath != null and .requestPath != ""))
   | map(select(.responseStatusCode != null))
   | . as $rows
   | ($rows | length) as $total
   | ($rows | map(select(.responseStatusCode == 404)) | length) as $n404
   | {
       total: $total,
       not_found: $n404,
       pct: (if $total > 0 then ($n404 * 100.0 / $total) else 0 end)
     }' "$norm")"
rm -f "$norm"

total="$(echo "$stats" | jq -r '.total')"
pct="$(echo "$stats" | jq -r '.pct')"

ratio_ok=1
if [ "${total:-0}" -ge "${SPIKE_MIN_SAMPLE}" ] 2>/dev/null; then
  if echo "$stats" | jq -e --argjson th "${NOT_FOUND_SPIKE_THRESHOLD_PCT}" '.pct > $th' >/dev/null; then
    ratio_ok=0
  fi
fi

echo "$stats" | jq --argjson p 1 --argjson d 1 --argjson r "$ratio_ok" \
  '{health: ((1 + 1 + $r) / 3), project_ok: $p, deployment_ok: $d, ratio_ok: $r,
    details: ("samples=" + (.total|tostring) + " 404_pct=" + (.pct|tostring)) }'

exit 0
