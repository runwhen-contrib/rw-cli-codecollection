#!/usr/bin/env bash
# SLI: scores 0 if current-week volume dropped beyond threshold vs historical avg.
set -euo pipefail
set -x

: "${MAILGUN_SENDING_DOMAIN:?}"
: "${MAILGUN_API_REGION:?}"
: "${MAILGUN_VOLUME_DROP_THRESHOLD_PCT:-80}"
API_KEY="${MAILGUN_API_KEY:-${mailgun_api_key:-}}"
: "${API_KEY:?Must set Mailgun API key secret}"

case "${MAILGUN_API_REGION}" in
  eu|EU) MG_BASE="https://api.eu.mailgun.net" ;;
  *) MG_BASE="https://api.mailgun.net" ;;
esac

url="${MG_BASE}/v1/analytics/metrics"
payload=$(jq -n \
  --arg domain "${MAILGUN_SENDING_DOMAIN}" \
  '{
    duration: "30d",
    metrics: ["delivered_count", "failed_count"],
    dimensions: ["time"],
    resolution: "day",
    filter: {
      AND: [
        { attribute: "domain", comparator: "=", values: [{ label: $domain, value: $domain }] }
      ]
    },
    include_aggregates: true
  }')

http_code=$(curl -sS --max-time 60 \
  -o /tmp/mg_sli_trend.json -w "%{http_code}" \
  -u "api:${API_KEY}" \
  -H "Content-Type: application/json" \
  -X POST -d "$payload" "$url") || true

if [[ "$http_code" != "200" ]]; then
  jq -n '{score: 0}'
  exit 0
fi

python3 - /tmp/mg_sli_trend.json "${MAILGUN_VOLUME_DROP_THRESHOLD_PCT}" <<'PYEOF'
import json, sys
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime

data_path, drop_thresh_str = sys.argv[1], sys.argv[2]
drop_threshold = float(drop_thresh_str)

with open(data_path) as f:
    data = json.load(f)

now = datetime.now(timezone.utc)
week_buckets = {0: 0, 1: 0, 2: 0, 3: 0}

for item in data.get("items", []):
    raw_date = item["dimensions"][0]["value"]
    dt = parsedate_to_datetime(raw_date)
    delivered = item["metrics"].get("delivered_count", 0) or 0
    failed = item["metrics"].get("failed_count", 0) or 0
    vol = delivered + failed
    days_ago = (now - dt).days
    week_idx = min(days_ago // 7, 3)
    week_buckets[week_idx] = week_buckets.get(week_idx, 0) + vol

historical_weeks = [week_buckets.get(i, 0) for i in range(1, 4)]
non_zero = [w for w in historical_weeks if w > 0]

if not non_zero or sum(non_zero) < 10:
    # Not enough historical data to judge — assume healthy
    json.dump({"score": 1}, sys.stdout)
    sys.exit(0)

historical_avg = sum(non_zero) / len(non_zero)
current_week = week_buckets.get(0, 0)
wow_change = ((current_week - historical_avg) / historical_avg) * 100

if wow_change <= -drop_threshold:
    json.dump({"score": 0, "detail": f"Volume down {wow_change:+.1f}% vs avg {historical_avg:.0f}"}, sys.stdout)
else:
    json.dump({"score": 1}, sys.stdout)
PYEOF
