#!/usr/bin/env bash
set -euo pipefail
set -x

# Queries OPEN / TRACKING Atlas project alerts (and recently updated CLOSED within lookback)
# when timestamps are present. Writes JSON issues to atlas_open_alerts_issues.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./atlas-helpers.sh
source "${SCRIPT_DIR}/atlas-helpers.sh"

: "${ATLAS_PROJECT_ID:?Must set ATLAS_PROJECT_ID}"
OUTPUT_FILE="${OUTPUT_FILE:-atlas_open_alerts_issues.json}"
ALERT_LOOKBACK_HOURS="${ALERT_LOOKBACK_HOURS:-24}"

issues_json='[]'

if ! atlas_resolve_credentials; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot Authenticate to MongoDB Atlas API for Project \`${ATLAS_PROJECT_ID}\`" \
    --arg details "Missing or unparsable Atlas API credentials." \
    --arg severity "4" \
    --arg next_steps "Configure workspace secret atlas_api_key_credentials (JSON with ATLAS_PUBLIC_API_KEY and ATLAS_PRIVATE_API_KEY) or set keys in the environment." \
    '. += [{ "title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps }]')
  echo "$issues_json" >"$OUTPUT_FILE"
  echo "Atlas credentials missing."
  exit 0
fi

acc='[]'
page=1
while true; do
  atlas_get "groups/${ATLAS_PROJECT_ID}/alerts?itemsPerPage=100&pageNum=${page}&includeCount=true"
  if [[ "$ATLAS_LAST_HTTP_CODE" != "200" ]]; then
    err="$(echo "$ATLAS_LAST_BODY" | jq -r '.detail // .reason // .error // "HTTP '"$ATLAS_LAST_HTTP_CODE"'"' 2>/dev/null || echo "HTTP $ATLAS_LAST_HTTP_CODE")"
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Atlas Alerts API Error for Project \`${ATLAS_PROJECT_ID}\`" \
      --arg details "GET alerts failed: ${err}" \
      --arg severity "4" \
      --arg next_steps "Verify ATLAS_PROJECT_ID, API key roles (Project Read Only+), and network access to cloud.mongodb.com." \
      '. += [{ "title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps }]')
    echo "$issues_json" >"$OUTPUT_FILE"
    echo "Alerts API error: $err"
    exit 0
  fi
  chunk="$(echo "$ATLAS_LAST_BODY" | jq -c '.results // []')"
  len="$(echo "$chunk" | jq 'length')"
  acc="$(echo "$acc" "$chunk" | jq -s 'add')"
  if [[ "$len" -lt 100 ]]; then
    break
  fi
  page=$((page + 1))
  if [[ "$page" -gt 50 ]]; then
    echo "Stopped pagination at page 50 (safety cap)."
    break
  fi
done

lookback_sec=$((ALERT_LOOKBACK_HOURS * 3600))
now_ts="$(date +%s)"

is_recent_ts() {
  local ts="$1"
  [[ -z "$ts" || "$ts" == "null" ]] && return 1
  local alert_ts
  if ! alert_ts="$(date -d "$ts" +%s 2>/dev/null)"; then
    return 1
  fi
  [[ $((now_ts - alert_ts)) -le $lookback_sec ]]
}

critical_heuristic() {
  local t="$1"
  echo "$t" | grep -qiE 'DOWN|UNREACHABLE|FAIL|PRIMARY|NO_PRIMARY|INACTIVE|OUTAGE' && return 0
  return 1
}

declare -a interesting_alerts=()
declare -a clusters_hit=()

while IFS= read -r row; do
  [[ -z "$row" ]] && continue
  cname="$(echo "$row" | jq -r '.clusterName // .clusterId // ""')"
  if [[ -n "$cname" ]] && ! cluster_matches_filter "$cname"; then
    continue
  fi
  st="$(echo "$row" | jq -r '.status // ""')"
  typ="$(echo "$row" | jq -r '.typeName // .eventTypeName // .metricName // "alert"')"
  hum="$(echo "$row" | jq -r '.humanReadable // .message // ""' | head -c 500 | tr '|' ' ')"
  updated="$(echo "$row" | jq -r '.updated // .lastNotified // .created // ""')"

  include=0
  if [[ "$st" == "OPEN" || "$st" == "TRACKING" ]]; then
    include=1
  elif [[ "$st" == "CLOSED" ]] && is_recent_ts "$updated"; then
    include=1
  fi

  if [[ "$include" -eq 1 ]]; then
    interesting_alerts+=("${st}|${typ}|${cname}|${hum}")
    if [[ -n "$cname" ]]; then
      clusters_hit+=("$cname")
    fi
  fi
done < <(echo "$acc" | jq -c '.[]')

uniq_clusters="$(printf '%s\n' "${clusters_hit[@]:-}" | sort -u | paste -sd, -)"
n="${#interesting_alerts[@]}"

summary_lines="$(printf '%s\n' "${interesting_alerts[@]:-}" | head -25)"
blast_radius="$(printf '%s\n' "${clusters_hit[@]:-}" | sort -u | grep -cve '^$' || true)"

echo "Open/recent alerts in scope: ${n} (distinct clusters in blast radius: ${blast_radius})"
echo "${summary_lines}"

if [[ "$n" -gt 0 ]]; then
  max_sev=2
  for line in "${interesting_alerts[@]}"; do
    typ="$(echo "$line" | cut -d'|' -f2)"
    if critical_heuristic "$typ"; then
      max_sev=4
      break
    fi
  done
  det="count=${n}; clusters=${uniq_clusters:-n/a}; sample=(first 25 lines):"$'\n'"${summary_lines}"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "MongoDB Atlas Alerts Require Attention in Project \`${ATLAS_PROJECT_ID}\`" \
    --arg details "$det" \
    --argjson severity "$max_sev" \
    --arg next_steps "Triage OPEN/TRACKING (and recent CLOSED) items in Atlas UI Alerts tab; correlate with clusterName; follow Atlas alert type runbooks." \
    '. += [{ "title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps }]')
fi

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
exit 0
