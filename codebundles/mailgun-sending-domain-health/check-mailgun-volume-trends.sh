#!/usr/bin/env bash
# Analyze 30-day Mailgun volume trends: daily breakdown, week-over-week, cliff detection.
set -euo pipefail
set -x

: "${MAILGUN_SENDING_DOMAIN:?}"
: "${MAILGUN_API_REGION:?}"
: "${MAILGUN_VOLUME_DROP_THRESHOLD_PCT:-80}"
API_KEY="${MAILGUN_API_KEY:-${mailgun_api_key:-}}"
: "${API_KEY:?Must set Mailgun API key secret}"

OUT="mailgun_volume_trend_issues.json"
issues_json='[]'

case "${MAILGUN_API_REGION}" in
  eu|EU) MG_BASE="https://api.eu.mailgun.net" ;;
  *) MG_BASE="https://api.mailgun.net" ;;
esac

url="${MG_BASE}/v1/analytics/metrics"
payload=$(jq -n \
  --arg domain "${MAILGUN_SENDING_DOMAIN}" \
  '{
    duration: "30d",
    metrics: ["delivered_count", "failed_count", "accepted_outgoing_count", "bounced_count", "complained_count", "suppressed_bounces_count", "suppressed_complaints_count", "suppressed_unsubscribed_count", "rate_limit_count"],
    dimensions: ["time"],
    resolution: "day",
    filter: {
      AND: [
        { attribute: "domain", comparator: "=", values: [{ label: $domain, value: $domain }] }
      ]
    },
    include_aggregates: true
  }')

http_code=$(curl -sS --max-time 90 \
  -o /tmp/mg_trends.json -w "%{http_code}" \
  -u "api:${API_KEY}" \
  -H "Content-Type: application/json" \
  -X POST -d "$payload" "$url") || true

if [[ "$http_code" != "200" ]]; then
  body=$(cat /tmp/mg_trends.json 2>/dev/null || true)
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Mailgun metrics API error fetching trends for \`${MAILGUN_SENDING_DOMAIN}\`" \
    --arg details "HTTP ${http_code}. ${body:0:400}" \
    --argjson severity 3 \
    --arg next_steps "Verify API key permissions and region; retry later." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" >"$OUT"
  cat "$OUT"
  exit 0
fi

agg_delivered=$(jq -r '.aggregates.metrics.delivered_count // 0' /tmp/mg_trends.json)
agg_failed=$(jq -r '.aggregates.metrics.failed_count // 0' /tmp/mg_trends.json)
agg_accepted=$(jq -r '.aggregates.metrics.accepted_outgoing_count // 0' /tmp/mg_trends.json)
agg_sup_bounce=$(jq -r '.aggregates.metrics.suppressed_bounces_count // 0' /tmp/mg_trends.json)
agg_sup_complaint=$(jq -r '.aggregates.metrics.suppressed_complaints_count // 0' /tmp/mg_trends.json)
agg_sup_unsub=$(jq -r '.aggregates.metrics.suppressed_unsubscribed_count // 0' /tmp/mg_trends.json)
agg_rate_limit=$(jq -r '.aggregates.metrics.rate_limit_count // 0' /tmp/mg_trends.json)
num_days=$(jq '.items | length' /tmp/mg_trends.json)

echo "=== 30-Day Volume Trend for ${MAILGUN_SENDING_DOMAIN} ==="
echo "Aggregate: Delivered=${agg_delivered}, Failed=${agg_failed}, Accepted=${agg_accepted} over ${num_days} active day(s)"
echo "Suppressions: Bounces=${agg_sup_bounce}, Complaints=${agg_sup_complaint}, Unsubscribes=${agg_sup_unsub} | Rate-limited: ${agg_rate_limit}"
echo ""

jq -r '.items[] |
  [(.dimensions[0].value | split(",")[1] | ltrimstr(" ") | split(" ")[0:3] | join(" ")),
   (.metrics.delivered_count // 0),
   (.metrics.failed_count // 0),
   (.metrics.accepted_outgoing_count // 0),
   (.metrics.suppressed_bounces_count // 0),
   (.metrics.suppressed_complaints_count // 0),
   (.metrics.suppressed_unsubscribed_count // 0),
   (.metrics.rate_limit_count // 0)] | @tsv
' /tmp/mg_trends.json > /tmp/mg_daily.tsv

echo "--- Daily Breakdown ---"
printf "%-14s %10s %8s %10s %10s %10s %10s %10s\n" "Date" "Delivered" "Failed" "Accepted" "Sup.Bounce" "Sup.Compl" "Sup.Unsub" "RateLimit"
while IFS=$'\t' read -r dt del fail acc sb sc su rl; do
  printf "%-14s %10s %8s %10s %10s %10s %10s %10s\n" "$dt" "$del" "$fail" "$acc" "$sb" "$sc" "$su" "$rl"
done < /tmp/mg_daily.tsv
echo ""

# Single Python pass for display + issue generation (avoids duplicated logic)
python3 - /tmp/mg_trends.json "${MAILGUN_VOLUME_DROP_THRESHOLD_PCT}" "${MAILGUN_SENDING_DOMAIN}" <<'PYEOF' > /tmp/mg_trend_issues.json
import json, sys
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime

data_path, drop_thresh_str, domain = sys.argv[1], sys.argv[2], sys.argv[3]
drop_threshold = float(drop_thresh_str)

with open(data_path) as f:
    data = json.load(f)

now = datetime.now(timezone.utc)
week_buckets = {0: 0, 1: 0, 2: 0, 3: 0}
daily_volumes = []
total_sup_bounce = 0
total_sup_complaint = 0
total_sup_unsub = 0
total_rate_limit = 0

for item in data.get("items", []):
    raw_date = item["dimensions"][0]["value"]
    dt = parsedate_to_datetime(raw_date)
    m = item["metrics"]
    delivered = m.get("delivered_count", 0) or 0
    failed = m.get("failed_count", 0) or 0
    sup_b = m.get("suppressed_bounces_count", 0) or 0
    sup_c = m.get("suppressed_complaints_count", 0) or 0
    sup_u = m.get("suppressed_unsubscribed_count", 0) or 0
    rl = m.get("rate_limit_count", 0) or 0
    vol = delivered + failed
    daily_volumes.append((dt, vol, delivered, failed, sup_b, sup_c, sup_u, rl))
    total_sup_bounce += sup_b
    total_sup_complaint += sup_c
    total_sup_unsub += sup_u
    total_rate_limit += rl
    days_ago = (now - dt).days
    week_idx = min(days_ago // 7, 3)
    week_buckets[week_idx] = week_buckets.get(week_idx, 0) + vol

daily_volumes.sort(key=lambda x: x[0])
issues = []

# --- Suppression & rate-limit diagnosis ---
total_suppressed = total_sup_bounce + total_sup_complaint + total_sup_unsub
agg = data.get("aggregates", {}).get("metrics", {})
agg_accepted = (agg.get("accepted_outgoing_count", 0) or 0)

print("--- Mailgun-Side Diagnostics (30-day totals) ---", file=sys.stderr)
print(f"  Suppressed (bounce):     {total_sup_bounce:>8,}", file=sys.stderr)
print(f"  Suppressed (complaint):  {total_sup_complaint:>8,}", file=sys.stderr)
print(f"  Suppressed (unsubscribe):{total_sup_unsub:>8,}", file=sys.stderr)
print(f"  Rate-limited:            {total_rate_limit:>8,}", file=sys.stderr)
print(file=sys.stderr)

if total_suppressed > 0 and agg_accepted > 0:
    sup_pct = (total_suppressed / (agg_accepted + total_suppressed)) * 100
    if sup_pct >= 5:
        issues.append({
            "severity": 2,
            "title": f"Significant Mailgun suppressions for `{domain}`: {total_suppressed:,} messages blocked",
            "details": (
                f"Over 30 days, {total_suppressed:,} messages were suppressed "
                f"(bounces={total_sup_bounce:,}, complaints={total_sup_complaint:,}, "
                f"unsubs={total_sup_unsub:,}) out of {agg_accepted + total_suppressed:,} "
                f"total attempted ({sup_pct:.1f}%). "
                "Suppressions prevent delivery to known-bad addresses."
            ),
            "next_steps": (
                "Review Mailgun suppression lists (bounces, complaints, unsubscribes) "
                "for this domain. Clean or appeal entries if they are stale. "
                "Check if a bad send batch inflated the suppression list."
            )
        })
    else:
        print(f"  Suppression rate: {sup_pct:.2f}% of attempted volume (below 5% threshold — not a concern)", file=sys.stderr)
elif total_suppressed == 0:
    print("  No suppressions detected — Mailgun is not blocking any recipients.", file=sys.stderr)

if total_rate_limit > 0:
    issues.append({
        "severity": 2,
        "title": f"Mailgun rate limiting detected for `{domain}`: {total_rate_limit:,} messages throttled",
        "details": (
            f"Over 30 days, {total_rate_limit:,} messages were rate-limited. "
            "This means Mailgun throttled sending, potentially causing volume drops."
        ),
        "next_steps": (
            "Review Mailgun account plan limits and sending patterns. "
            "Contact Mailgun support if rate limits are unexpected. "
            "Consider spreading sends over longer windows."
        )
    })
else:
    print("  No rate limiting detected — Mailgun did not throttle this domain.", file=sys.stderr)

print(file=sys.stderr)

# --- Week-over-week summary ---
print("--- Week-over-Week Summary (delivered + failed) ---", file=sys.stderr)
labels = ["This week (0-6d ago)", "Last week (7-13d ago)", "2 weeks ago (14-20d)", "3 weeks ago (21-27d)"]
for i in range(4):
    print(f"  {labels[i]:30s}: {week_buckets.get(i, 0):>8,}", file=sys.stderr)
print(file=sys.stderr)

# --- Day-over-day cliff detection ---
if len(daily_volumes) >= 2:
    print("--- Day-over-Day Changes ---", file=sys.stderr)
    for i in range(1, len(daily_volumes)):
        prev_dt, prev_vol = daily_volumes[i-1][0], daily_volumes[i-1][1]
        curr_dt, curr_vol = daily_volumes[i][0], daily_volumes[i][1]
        if prev_vol > 0:
            change_pct = ((curr_vol - prev_vol) / prev_vol) * 100
        elif curr_vol > 0:
            change_pct = 100.0
        else:
            change_pct = 0.0
        marker = ""
        if change_pct <= -drop_threshold:
            marker = " *** CLIFF DROP ***"
        elif change_pct <= -50:
            marker = " ** significant decline **"
        print(f"  {prev_dt.strftime('%b %d')} ({prev_vol:,}) -> {curr_dt.strftime('%b %d')} ({curr_vol:,}): {change_pct:+.1f}%{marker}", file=sys.stderr)

        if change_pct <= -drop_threshold and prev_vol >= 10:
            issues.append({
                "severity": 2,
                "title": f"Volume cliff on {curr_dt.strftime('%b %d')}: {change_pct:+.1f}% drop for `{domain}`",
                "details": (
                    f"{prev_dt.strftime('%Y-%m-%d')} had {prev_vol:,} messages, "
                    f"{curr_dt.strftime('%Y-%m-%d')} dropped to {curr_vol:,} "
                    f"({change_pct:+.1f}% change, threshold -{drop_thresh_str}%)."
                ),
                "next_steps": (
                    "Investigate what changed on this date: application deployments, "
                    "Mailgun configuration changes, DNS modifications, or upstream "
                    "systems that generate email. Check Mailgun suppressions and logs."
                )
            })
    print(file=sys.stderr)

# --- Week-over-week decline ---
historical_weeks = [week_buckets.get(i, 0) for i in range(1, 4)]
historical_avg = sum(historical_weeks) / max(len([w for w in historical_weeks if w > 0]), 1)
current_week = week_buckets.get(0, 0)

if historical_avg > 10:
    wow_change = ((current_week - historical_avg) / historical_avg) * 100
    print(f"Current week volume: {current_week:,}, Historical weekly avg: {historical_avg:,.0f}, Change: {wow_change:+.1f}%", file=sys.stderr)
    if wow_change <= -drop_threshold:
        issues.append({
            "severity": 2,
            "title": f"Current week volume down {wow_change:+.1f}% vs historical avg for `{domain}`",
            "details": (
                f"This week: {current_week:,} messages. "
                f"Historical weekly average (weeks 1-3): {historical_avg:,.0f}. "
                f"Change: {wow_change:+.1f}% (threshold: -{drop_thresh_str}%)."
            ),
            "next_steps": (
                "Sustained volume decline may indicate a misconfiguration, "
                "application change, or migration away from Mailgun. "
                "Review application logs, Mailgun dashboard, and recent changes."
            )
        })

# --- Verdict ---
mg_side_issues = [i for i in issues if "suppress" in i["title"].lower() or "rate limit" in i["title"].lower()]
if not mg_side_issues:
    print(file=sys.stderr)
    print("=== VERDICT: No Mailgun-side blockers found (no suppressions, no rate limiting). ===", file=sys.stderr)
    print("    Volume drop is likely caused by upstream application changes, not Mailgun.", file=sys.stderr)

json.dump(issues, sys.stdout, indent=2)
PYEOF

issues_json=$(cat /tmp/mg_trend_issues.json)
echo "$issues_json" >"$OUT"
