#!/usr/bin/env bash
# Lightweight Cloudflare GraphQL probe used by sli.robot — emits one-line JSON scores on stdout.
set -euo pipefail

: "${CLOUDFLARE_ZONE_ID:?Must set CLOUDFLARE_ZONE_ID}"

TOKEN="${CLOUDFLARE_API_TOKEN:-${cloudflare_api_token:-}}"
GRAPHQL_URL="${CLOUDFLARE_GRAPHQL_URL:-https://api.cloudflare.com/client/v4/graphql}"
LOOKBACK="${SLI_WAF_LOOKBACK_MINUTES:-15}"
MAX_ROWS="${SLI_WAF_MAX_SAMPLE_ROWS:-400}"
thr="${SLI_WAF_MAX_EVENTS:-250}"

api_ok=0
volume_ok=1

if [[ -z "${TOKEN}" ]]; then
  jq -n \
    --argjson api_ok 0 \
    --argjson volume_ok 0 \
    --argjson rows 0 \
    --argjson thr "${thr}" \
    '{api_ok:$api_ok, volume_ok:$volume_ok, primary_rows:$rows, threshold:$thr}'
  exit 0
fi

end_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_iso=$(date -u -d "-${LOOKBACK} minutes" +%Y-%m-%dT%H:%M:%SZ)

body="$(jq -n \
  --arg z "${CLOUDFLARE_ZONE_ID}" \
  --arg ds "$start_iso" \
  --arg de "$end_iso" \
  --argjson lim "${MAX_ROWS}" \
  '{
    query: "query ($zoneTag: string, $filter: FirewallEventsAdaptiveFilter_InputObject!, $limit: int!) { viewer { zones(filter: { zoneTag: $zoneTag }) { firewallEventsAdaptive(filter: $filter, limit: $limit, orderBy: [datetime_DESC]) { datetime action source clientIP } } } }",
    variables: {
      zoneTag: $z,
      filter: { datetime_geq: $ds, datetime_leq: $de },
      limit: $lim
    }
  }' \
  | curl -sS --max-time 45 \
      "$GRAPHQL_URL" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d @-)"

rows=$(echo "$body" | jq '[ .data.viewer.zones[0].firewallEventsAdaptive[]? ] | length')
err_count=$(echo "$body" | jq '.errors | length // 0')
zones_len=$(echo "$body" | jq '[ .data.viewer.zones[]? ] | length')

if [[ "${err_count}" -gt 0 ]]; then
  api_ok=0
elif [[ "${zones_len}" -eq 0 ]]; then
  api_ok=0
else
  api_ok=1
fi

volume_ok=0
if [[ "${api_ok}" -eq 1 ]]; then
  if [[ "${rows}" -le "${thr}" ]]; then
    volume_ok=1
  fi
fi

jq -n \
  --argjson api_ok "${api_ok}" \
  --argjson volume_ok "${volume_ok}" \
  --argjson rows "${rows}" \
  --argjson thr "${thr}" \
  '{api_ok:$api_ok, volume_ok:$volume_ok, primary_rows:$rows, threshold:$thr}'
