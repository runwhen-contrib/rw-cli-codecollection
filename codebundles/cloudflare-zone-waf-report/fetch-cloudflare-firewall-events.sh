#!/usr/bin/env bash
# Fetch sampled firewall/WAF events for the configured Cloudflare zone via GraphQL Analytics
# (firewallEventsAdaptive). Writes normalized JSON for aggregation scripts.
#
# Outputs:
#   cloudflare_waf_primary_normalized.json — { meta, events: [...] }
#   cloudflare_waf_prior_normalized.json — optional compare window (empty payload when compare disabled)
#   cloudflare_waf_fetch_issues.json — Robot issue payloads (API/auth failures)
#
# Notes:
#   - firewallEventsAdaptive is adaptively sampled; counts reflect sampled hits returned by GraphQL,
#     while Cloudflare may extrapolate totals internally on dashboards.
set -euo pipefail
set -x

: "${CLOUDFLARE_ZONE_ID:?Must set CLOUDFLARE_ZONE_ID}"

TOKEN="${CLOUDFLARE_API_TOKEN:-${cloudflare_api_token:-}}"
GRAPHQL_URL="${CLOUDFLARE_GRAPHQL_URL:-https://api.cloudflare.com/client/v4/graphql}"

PRIMARY_OUT="${CLOUDFLARE_WAF_PRIMARY_JSON:-cloudflare_waf_primary_normalized.json}"
PRIOR_OUT="${CLOUDFLARE_WAF_PRIOR_JSON:-cloudflare_waf_prior_normalized.json}"
ISSUES_OUT="${CLOUDFLARE_WAF_FETCH_ISSUES:-cloudflare_waf_fetch_issues.json}"

LOOKBACK="${WAF_LOOKBACK_MINUTES:-60}"
COMPARE="${WAF_COMPARE_LOOKBACK_MINUTES:-60}"
PAGE_LIMIT="${WAF_FETCH_PAGE_LIMIT:-800}"
MAX_PAGES="${WAF_FETCH_MAX_PAGES:-25}"

issues_json='[]'

die_issue() {
  local title="$1" details="$2" severity="${3:-4}" next="${4:-Verify CLOUDFLARE_ZONE_ID, token scopes (Analytics read + Firewall/WAF read), and network egress to api.cloudflare.com.}"
  issues_json=$(echo "$issues_json" | jq \
    --arg t "$title" \
    --arg d "$details" \
    --arg ns "$next" \
    --argjson sev "$severity" \
    '. += [{"title": $t, "details": $d, "severity": $sev, "next_steps": $ns}]')
}

firewall_graphql_call() {
  local zone="$1" start_iso="$2" end_iso="$3" limit="$4"
  jq -n \
    --arg z "$zone" \
    --arg ds "$start_iso" \
    --arg de "$end_iso" \
    --argjson lim "$limit" \
    '{
      query: "query ($zoneTag: string, $filter: FirewallEventsAdaptiveFilter_InputObject!, $limit: int!) { viewer { zones(filter: { zoneTag: $zoneTag }) { firewallEventsAdaptive(filter: $filter, limit: $limit, orderBy: [datetime_DESC]) { action clientAsn clientCountryName clientIP clientRequestPath clientRequestQuery datetime source userAgent ruleId description clientRequestHTTPHostName } } } }",
      variables: {
        zoneTag: $z,
        filter: { datetime_geq: $ds, datetime_leq: $de },
        limit: $lim
      }
    }' \
    | curl -sS --max-time 120 \
      "$GRAPHQL_URL" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d @-
}

firewall_graphql_fallback_call() {
  local zone="$1" start_iso="$2" end_iso="$3" limit="$4"
  jq -n \
    --arg z "$zone" \
    --arg ds "$start_iso" \
    --arg de "$end_iso" \
    --argjson lim "$limit" \
    '{
      query: "query ($zoneTag: string, $filter: FirewallEventsAdaptiveFilter_InputObject!, $limit: int!) { viewer { zones(filter: { zoneTag: $zoneTag }) { firewallEventsAdaptive(filter: $filter, limit: $limit, orderBy: [datetime_DESC]) { action clientAsn clientCountryName clientIP clientRequestPath clientRequestQuery datetime source userAgent } } } }",
      variables: {
        zoneTag: $z,
        filter: { datetime_geq: $ds, datetime_leq: $de },
        limit: $lim
      }
    }' \
    | curl -sS --max-time 120 \
      "$GRAPHQL_URL" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d @-
}

graphql_firewall_page() {
  local zone="$1" start_iso="$2" end_iso="$3" limit="$4"
  local body

  body="$(firewall_graphql_call "$zone" "$start_iso" "$end_iso" "$limit")" || return 1

  if echo "$body" | jq -e '.errors != null and (.errors | length > 0)' >/dev/null; then
    # Retry without optional columns some tenants/schemas omit.
    body="$(firewall_graphql_fallback_call "$zone" "$start_iso" "$end_iso" "$limit")" || return 1
    if echo "$body" | jq -e '.errors != null and (.errors | length > 0)' >/dev/null; then
      echo "$body" | jq -c '.errors' >&2
      return 2
    fi
  fi

  local zones
  zones=$(echo "$body" | jq '[ .data.viewer.zones[]? ] | length')
  if [[ "${zones:-0}" -eq 0 ]]; then
    return 3
  fi

  echo "$body" | jq -c '.data.viewer.zones[0].firewallEventsAdaptive // []'
}

collect_window() {
  local zone="$1" start_iso="$2" end_iso="$3"
  local agg='[]' oldest iso_old=""
  local i

  for ((i = 1; i <= MAX_PAGES; i++)); do
    local batch_json rc
    batch_json="$(graphql_firewall_page "$zone" "$start_iso" "$end_iso" "$PAGE_LIMIT")" && rc=0 || rc=$?
    if [[ "$rc" == "1" ]]; then
      die_issue "Cloudflare GraphQL HTTP failure for zone \`${zone}\`" "curl exited non-zero while calling ${GRAPHQL_URL}" 4
      echo "$agg"
      return 1
    fi
    if [[ "$rc" == "2" ]]; then
      local detail
      detail="$(firewall_graphql_call "$zone" "$start_iso" "$end_iso" "$PAGE_LIMIT" | jq -c '.errors // []')"
      die_issue "Cloudflare GraphQL errors for zone \`${zone}\`" "GraphQL errors: ${detail}" 4 \
        "Confirm token Analytics/Firewall scopes per Cloudflare token templates; see https://developers.cloudflare.com/analytics/graphql-api/getting-started/authentication/api-token-auth/"
      echo "$agg"
      return 1
    fi
    if [[ "$rc" == "3" ]]; then
      die_issue "Cloudflare zone not returned by Analytics GraphQL for \`${zone}\`" "zones(filter:{zoneTag}) returned zero zones — verify zone tag/id matches Analytics datasets." 4
      echo "$agg"
      return 1
    fi

    local n
    n=$(echo "$batch_json" | jq 'length')
    if [[ "${n:-0}" -eq 0 ]]; then
      break
    fi

    agg="$(jq -s 'add' <<<"$agg"$'\n'"${batch_json}")"

    if [[ "$n" -lt "$PAGE_LIMIT" ]]; then
      break
    fi

    oldest=$(echo "$batch_json" | jq -r 'map(.datetime) | min')
    if [[ -z "$oldest" || "$oldest" == "null" ]]; then
      break
    fi
    if [[ "$oldest" == "$iso_old" ]]; then
      break
    fi
    iso_old="$oldest"

    # Move exclusive upper bound slightly earlier than the oldest row so DESC paging can proceed.
    local oldest_epoch prior_epoch new_end
    oldest_epoch=$(date -u -d "${oldest/Z/+0000}" +%s 2>/dev/null || date -u -d "$oldest" +%s)
    prior_epoch=$((oldest_epoch - 1))
    new_end=$(date -u -d "@${prior_epoch}" +%Y-%m-%dT%H:%M:%SZ)
    end_iso="$new_end"

    if [[ "$(echo "$agg" | jq 'length')" -ge "$((PAGE_LIMIT * MAX_PAGES))" ]]; then
      break
    fi
  done

  echo "$agg"
}

if [[ -z "${TOKEN}" ]]; then
  die_issue "Missing Cloudflare API token for zone \`${CLOUDFLARE_ZONE_ID}\`" "Set secret cloudflare_api_token / CLOUDFLARE_API_TOKEN with Analytics read scope." 4
fi

end_primary=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_primary=$(date -u -d "-${LOOKBACK} minutes" +%Y-%m-%dT%H:%M:%SZ)

events_primary="$(collect_window "$CLOUDFLARE_ZONE_ID" "$start_primary" "$end_primary")"

lookback_num=$((LOOKBACK + 0))

jq -n \
  --arg z "${CLOUDFLARE_ZONE_ID}" \
  --arg start "${start_primary}" \
  --arg end "${end_primary}" \
  --argjson lb "${lookback_num}" \
  --argjson ev "$(echo "${events_primary}" | jq -c '.')" \
  --arg note "Adaptive sampled firewallEventsAdaptive rows — dashboards may extrapolate beyond sampled hits." \
  --arg acct "${CLOUDFLARE_ACCOUNT_ID:-}" \
  '{
    meta: {
      zone_tag: $z,
      window: {start: $start, end: $end, lookback_minutes: $lb},
      effective_limits: {page_limit: '"${PAGE_LIMIT}"', max_pages: '"${MAX_PAGES}"'},
      dataset_note: $note,
      account_id_hint: $acct
    },
    events: $ev
  }' >"${PRIMARY_OUT}"

echo "[+] Primary window rows (sample hits): $(jq '.events | length' "${PRIMARY_OUT}") → ${PRIMARY_OUT}"

compare_num=$((COMPARE + 0))

if [[ "${compare_num}" -gt 0 ]]; then
  end_prior="${start_primary}"
  start_prior_epoch=$(( $(date -u +%s) - (lookback_num + compare_num) * 60 ))
  start_prior=$(date -u -d "@${start_prior_epoch}" +%Y-%m-%dT%H:%M:%SZ)
  events_prior="$(collect_window "$CLOUDFLARE_ZONE_ID" "$start_prior" "${end_prior}")"
  jq -n \
    --arg z "${CLOUDFLARE_ZONE_ID}" \
    --arg start "${start_prior}" \
    --arg end "${end_prior}" \
    --argjson ev "$(echo "${events_prior}" | jq -c '.')" \
    '{meta:{zone_tag:$z, window:{start:$start, end:$end}}, events:$ev}' >"${PRIOR_OUT}"
  echo "[+] Prior window rows (sample hits): $(jq '.events | length' "${PRIOR_OUT}") → ${PRIOR_OUT}"
else
  jq -n '{meta:{disabled:true, reason:"WAF_COMPARE_LOOKBACK_MINUTES is 0"}, events:[]}' >"${PRIOR_OUT}"
fi

echo "$issues_json" >"${ISSUES_OUT}"
echo "[+] Issues JSON written to ${ISSUES_OUT}"
