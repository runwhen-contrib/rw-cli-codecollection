#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# OPTIONAL ENV VARS:
#   SERVICES                 Comma-separated service names to check; 'All' checks all enabled services
#   QUOTA_WARNING_THRESHOLD  Consumption percentage of the rate limit that triggers an issue (0-100)
#   LOOKBACK_MINUTES         Lookback window (minutes) for rate quota metrics
#
# This script pulls Cloud Monitoring serviceruntime rate quota time-series
# (quota/rate/net_ingress, net_egress, per-method) over a lookback window,
# evaluates consumption against limits, and detects throttling events where
# requests were blocked due to rate limits.
# Outputs a JSON array of issues to rate_quota_issues.json
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${SERVICES:=All}"
: "${QUOTA_WARNING_THRESHOLD:=80}"
: "${LOOKBACK_MINUTES:=1440}"

OUTPUT_FILE="rate_quota_issues.json"
ISSUES_TMP="$(mktemp)"
trap 'rm -f "$ISSUES_TMP"' EXIT

echo "Checking rate quota consumption and throttling for project: $GCP_PROJECT_ID"

token=$(gcloud auth print-access-token 2>/dev/null || echo "")
if [ -z "$token" ]; then
  echo "Unable to obtain an access token; no rate quota checked."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

now_epoch=$(date +%s)
start_epoch=$((now_epoch - LOOKBACK_MINUTES * 60))

> "$ISSUES_TMP"

# -----------------------------------------------------------------------------
# Helper: fetch a Cloud Monitoring time-series for a given metric type filter
# and return a JSON array of {service, metric, region, value}
# -----------------------------------------------------------------------------
fetch_series() {
  local filter="$1"
  curl -s -H "Authorization: Bearer $token" \
    "https://monitoring.googleapis.com/v3/projects/$GCP_PROJECT_ID/timeSeries?filter=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$filter")&interval.startTime=${start_epoch}s&interval.endTime=${now_epoch}s&view=FULL&pageSize=1000" \
    2>/dev/null || echo "{}"
}

# Gather rate metrics for net_ingress, net_egress, and per-method
rate_series='[]'
for rate_type in net_usage; do
  resp=$(fetch_series "metric.type=\"serviceruntime.googleapis.com/quota/rate/$rate_type\"")
  parsed=$(echo "$resp" | jq -c '
    [.timeSeries[]? |
      {
        service: (.resource.labels.service // "unknown"),
        metric_type: .metric.type,
        limit_name: (.metric.labels.limit_name // .metric.labels.quota_metric // "unknown"),
        region: (.metric.labels.quota_location // .resource.labels.location // ""),
        values: [.points[].value.doubleValue // 0],
        points_count: ([.points[]?.value.doubleValue] | length)
      }]' 2>/dev/null || echo '[]')
  rate_series=$(echo "$rate_series $parsed" | jq -s 'add')
done

# Throttled time (seconds requests were blocked due to rate limit)
throttle_series=$(fetch_series "metric.type=\"serviceruntime.googleapis.com/quota/throttled_time\"")
throttle_data=$(echo "$throttle_series" | jq -c '
  [.timeSeries[]? |
    {
      service: (.resource.labels.service // "unknown"),
      metric_type: .metric.type,
      region: (.metric.labels.quota_location // ""),
      throttled_seconds: ([.points[].value.doubleValue // 0] | max // 0)
    }]' 2>/dev/null || echo '[]')

service_filter="$SERVICES"

# -----------------------------------------------------------------------------
# Evaluate each rate series against its quota limit
# -----------------------------------------------------------------------------
echo "$rate_series" | jq -c '.[]' | while IFS= read -r series; do
  service=$(echo "$series" | jq -r '.service')
  region=$(echo "$series" | jq -r '.region')
  metric_type=$(echo "$series" | jq -r '.metric_type')

  if [ -n "$service_filter" ] && [ "$service_filter" != "All" ] && [ "$service_filter" != "all" ]; then
    case ",$service_filter," in
      *,"$service",*) ;;
      *) continue ;;
    esac
  fi

  points_count=$(echo "$series" | jq -r '.points_count // 0')
  [ "$points_count" -eq 0 ] && continue

  # Peak rate within window (evaluate on max, not average)
  peak=$(echo "$series" | jq -r '[.values[]] | max // 0')

  # Resolve the rate limit from the Service Usage consumerQuotaMetrics for the
  # rate metric on the service; fall back to a nominal limit.
  limit_value="0"
  metrics_resp=$(curl -s -H "Authorization: Bearer $token" \
    "https://serviceusage.googleapis.com/v1/projects/$GCP_PROJECT_ID/services/$service/consumerQuotaMetrics?view=FULL&pageSize=500" 2>/dev/null || echo "{}")
  limit_value=$(echo "$metrics_resp" | jq -r --arg mt "$metric_type" \
    '[.metrics[]? | select(.metric == $mt) | .consumerQuotaLimits[]? | [.. | objects | .effectiveLimit? // 0] | max] | max // 0' 2>/dev/null || echo "0")

  if [ "$limit_value" = "null" ] || [ -z "$limit_value" ]; then
    limit_value="0"
  fi

  if python3 -c "import sys; sys.exit(0 if float('$limit_value') <= 0 else 1)" 2>/dev/null; then
    # Limit unknown; rely on throttling detection only for this series
    continue
  fi

  pct=$(python3 -c "
peak=float('$peak'); limit=float('$limit_value')
print(round(peak/limit*100,2) if limit>0 else 0)
" 2>/dev/null || echo "0")

  dims=""
  [ -n "$region" ] && dims=" (region: $region)"

  if python3 -c "import sys; sys.exit(0 if float('$pct') >= float('$QUOTA_WARNING_THRESHOLD') else 1)" 2>/dev/null; then
    if python3 -c "import sys; sys.exit(0 if float('$pct') >= 95 else 1)" 2>/dev/null; then
      severity="4"
    else
      severity="3"
    fi
    jq -n \
      --arg title "Rate quota near/over limit for service \`$service\` in project \`$GCP_PROJECT_ID\`" \
      --arg details "Rate quota metric \`$metric_type\`${dims} for service \`$service\` peaked at ${pct}% of its rate limit (peak ${peak} req/s, limit ${limit_value} req/s) over the last ${LOOKBACK_MINUTES} minutes." \
      --arg expected "Rate quota consumption should remain below ${QUOTA_WARNING_THRESHOLD}% of the rate limit" \
      --arg actual "Rate quota peaked at ${pct}% of limit (${peak} req/s of ${limit_value} req/s)" \
      --arg severity "$severity" \
      --arg next_steps "Reduce request rate to service $service or request a rate limit increase via the Cloud Quotas page to avoid throttling." \
      '{title:$title,details:$details,expected:$expected,actual:$actual,severity:($severity|tonumber),next_steps:$next_steps}' >> "$ISSUES_TMP"
  fi
done

# -----------------------------------------------------------------------------
# Detect throttling events (requests blocked due to rate limits)
# -----------------------------------------------------------------------------
echo "$throttle_data" | jq -c '.[]' | while IFS= read -r tseries; do
  service=$(echo "$tseries" | jq -r '.service')
  region=$(echo "$tseries" | jq -r '.region')
  throttled=$(echo "$tseries" | jq -r '.throttled_seconds // 0')

  if [ -n "$service_filter" ] && [ "$service_filter" != "All" ] && [ "$service_filter" != "all" ]; then
    case ",$service_filter," in
      *,"$service",*) ;;
      *) continue ;;
    esac
  fi

  if python3 -c "import sys; sys.exit(0 if float('$throttled') > 0 else 1)" 2>/dev/null; then
    dims=""
    [ -n "$region" ] && dims=" (region: $region)"
    jq -n \
      --arg title "Rate limiting/throttling detected for service \`$service\` in project \`$GCP_PROJECT_ID\`" \
      --arg details "Service \`$service\`${dims} experienced throttling: requests were blocked due to rate limits for ${throttled} seconds over the last ${LOOKBACK_MINUTES} minutes." \
      --arg expected "No requests should be throttled due to rate limits" \
      --arg actual "Requests were throttled for ${throttled} seconds in the lookback window" \
      --arg severity "4" \
      --arg next_steps "Investigate the request rate to $service, add retry/backoff handling, or raise the relevant rate limit via the Cloud Quotas page." \
      '{title:$title,details:$details,expected:$expected,actual:$actual,severity:($severity|tonumber),next_steps:$next_steps}' >> "$ISSUES_TMP"
  fi
done

if [ -s "$ISSUES_TMP" ]; then
  jq -s '.' "$ISSUES_TMP" > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Rate quota analysis completed: $(jq length "$OUTPUT_FILE") issue(s)."

echo ""
echo "=== LLM Context ==="
echo "Project: $GCP_PROJECT_ID"
echo "Lookback window: ${LOOKBACK_MINUTES} minutes"
echo "Quota warning threshold: ${QUOTA_WARNING_THRESHOLD}%"
echo "Cloud Monitoring metrics view: https://console.cloud.google.com/monitoring/metrics-explorer?project=$GCP_PROJECT_ID"
echo "Cloud Quotas console: https://console.cloud.google.com/quotas?project=$GCP_PROJECT_ID"
