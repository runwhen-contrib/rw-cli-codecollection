#!/usr/bin/env bash
set -euo pipefail
# -----------------------------------------------------------------------------
# Lightweight aggregate for SLI: page green + no unresolved incidents + regional
# API probes (401 + JSON). Prints one JSON object on stdout for sli.robot.
# Env: MAILGUN_STATUS_REGION_FOCUS (default both), MAILGUN_STATUS_LOOKBACK_HOURS (unused; reserved)
# -----------------------------------------------------------------------------

MAILGUN_STATUS_REGION_FOCUS="${MAILGUN_STATUS_REGION_FOCUS:-both}"

page_score=0
if status_json=$(curl -fsS --connect-timeout 5 --max-time 15 "https://status.mailgun.com/api/v2/status.json" 2>/dev/null); then
  if echo "$status_json" | jq -e '.status.indicator == "none"' >/dev/null 2>&1; then
    if unres_json=$(curl -fsS --connect-timeout 5 --max-time 15 "https://status.mailgun.com/api/v2/incidents/unresolved.json" 2>/dev/null); then
      if echo "$unres_json" | jq -e '(.incidents | length) == 0' >/dev/null 2>&1; then
        page_score=1
      fi
    fi
  fi
fi

probe_api() {
  local url="$1"
  local tmp
  tmp=$(mktemp)
  local code rc
  set +e
  code=$(curl -sS -o "$tmp" -w '%{http_code}' --connect-timeout 5 --max-time 15 -H 'Accept: application/json' "$url")
  rc=$?
  set -e
  local head
  head=$(head -c 300 "$tmp" || true)
  rm -f "$tmp"
  if [[ "$rc" -ne 0 || "$code" != "401" ]]; then
    echo "0"
    return
  fi
  if echo "$head" | jq -e . >/dev/null 2>&1; then
    echo "1"
  else
    echo "0"
  fi
}

us_score=-1
eu_score=-1
us_included=0
eu_included=0
if [[ "$MAILGUN_STATUS_REGION_FOCUS" == "both" || "$MAILGUN_STATUS_REGION_FOCUS" == "us" ]]; then
  us_score=$(probe_api "https://api.mailgun.net/v3/domains")
  us_included=1
fi
if [[ "$MAILGUN_STATUS_REGION_FOCUS" == "both" || "$MAILGUN_STATUS_REGION_FOCUS" == "eu" ]]; then
  eu_score=$(probe_api "https://api.eu.mailgun.net/v3/domains")
  eu_included=1
fi

dims=0
sum=0
sum=$((sum + page_score))
dims=$((dims + 1))
if [[ "$MAILGUN_STATUS_REGION_FOCUS" == "both" || "$MAILGUN_STATUS_REGION_FOCUS" == "us" ]]; then
  sum=$((sum + us_score))
  dims=$((dims + 1))
fi
if [[ "$MAILGUN_STATUS_REGION_FOCUS" == "both" || "$MAILGUN_STATUS_REGION_FOCUS" == "eu" ]]; then
  sum=$((sum + eu_score))
  dims=$((dims + 1))
fi

health_score=$(awk -v s="$sum" -v d="$dims" 'BEGIN { if (d < 1) { print 0 } else { printf "%.4f", s / d } }')

jq -n \
  --argjson page "$page_score" \
  --argjson us_raw "$us_score" \
  --argjson eu_raw "$eu_score" \
  --argjson us_included "$us_included" \
  --argjson eu_included "$eu_included" \
  --argjson health "$health_score" \
  '{page: $page, us: (if $us_included == 0 then null else $us_raw end), eu: (if $eu_included == 0 then null else $eu_raw end), us_included: ($us_included == 1), eu_included: ($eu_included == 1), health_score: $health}'
