#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# OPTIONAL ENV VARS:
#   SERVICES                 Comma-separated service names to check; 'All' checks all enabled services
#   QUOTA_WARNING_THRESHOLD  Usage percentage of a quota limit that triggers an issue (0-100)
#   LOOKBACK_MINUTES         Lookback window (minutes) for rate quota usage
#
# This script cross-references all discovered quota metrics (allocation and
# rate) against the configured QUOTA_WARNING_THRESHOLD and raises an issue for
# every quota whose current usage equals or exceeds that threshold, providing
# service, quota dimension, usage, limit, and percentage.
# If the Cloud Quotas API is enabled, its authoritative limit is preferred.
# Outputs a JSON array of issues to quota_threshold_issues.json
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${SERVICES:=All}"
: "${QUOTA_WARNING_THRESHOLD:=80}"
: "${LOOKBACK_MINUTES:=1440}"

OUTPUT_FILE="quota_threshold_issues.json"
ISSUES_TMP="$(mktemp)"
trap 'rm -f "$ISSUES_TMP"' EXIT

echo "Identifying quotas above ${QUOTA_WARNING_THRESHOLD}% for project: $GCP_PROJECT_ID"

token=$(gcloud auth print-access-token 2>/dev/null || echo "")
if [ -z "$token" ]; then
  echo "Unable to obtain an access token; no quotas assessed."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

now_epoch=$(date +%s)
start_epoch=$((now_epoch - LOOKBACK_MINUTES * 60))

> "$ISSUES_TMP"

# -----------------------------------------------------------------------------
# 1. Enumerate enabled services
# -----------------------------------------------------------------------------
services_json=$(curl -s -H "Authorization: Bearer $token" \
  "https://serviceusage.googleapis.com/v1/projects/$GCP_PROJECT_ID/services?filter=state%3AENABLED&pageSize=300" 2>/dev/null || echo "{}")

if ! echo "$services_json" | jq -e '.services' >/dev/null 2>&1; then
  echo "Service Usage API did not return services."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

service_names=$(echo "$services_json" | jq -r '.services[].config.name // empty' | sort -u)

if [ -n "$SERVICES" ] && [ "$SERVICES" != "All" ] && [ "$SERVICES" != "all" ]; then
  wanted=$(echo "$SERVICES" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  filtered=""
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    while IFS= read -r w; do
      [ -z "$w" ] && continue
      if [ "$s" = "$w" ] || [ "${s#*/}" = "$w" ]; then
        filtered="$filtered
$s"
        break
      fi
    done <<< "$wanted"
  done <<< "$service_names"
  service_names=$(echo "$filtered" | sed '/^$/d')
fi

if [ -z "$service_names" ]; then
  echo "No enabled services matched the SERVICES filter."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

# -----------------------------------------------------------------------------
# 2. Gather current usage from Cloud Monitoring (allocation + rate)
# -----------------------------------------------------------------------------
fetch_series() {
  local filter="$1"
  curl -s -H "Authorization: Bearer $token" \
    "https://monitoring.googleapis.com/v3/projects/$GCP_PROJECT_ID/timeSeries?filter=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$filter")&interval.startTime=${start_epoch}s&interval.endTime=${now_epoch}s&view=FULL&pageSize=1000" \
    2>/dev/null || echo "{}"
}

usage_rows='[]'
for mtype in "serviceruntime.googleapis.com/quota/allocation" \
             "serviceruntime.googleapis.com/quota/rate/net_ingress" \
             "serviceruntime.googleapis.com/quota/rate/net_egress" \
             "serviceruntime.googleapis.com/quota/rate/per_method"; do
  resp=$(fetch_series "metric.type=\"$mtype\"")
  parsed=$(echo "$resp" | jq -c --arg mt "$mtype" '
    [.timeSeries[]? |
      {
        service: (.resource.labels.service // "unknown"),
        quota_metric: (.metric.labels.quota_metric // .metric.labels.limit_name // (.metric.type | split("/")[-1])),
        region: (.metric.labels.quota_location // .resource.labels.location // ""),
        usage: ([.points[].value.doubleValue // 0] | max // 0),
        kind: (if ($mt | contains("allocation")) then "allocation" else "rate" end)
      }]' 2>/dev/null || echo '[]')
  usage_rows=$(echo "$usage_rows $parsed" | jq -s 'add')
done

# -----------------------------------------------------------------------------
# 3. Resolve per-service quota limits and flag any usage above the threshold
# -----------------------------------------------------------------------------
echo "$usage_rows" | jq -c 'unique' | while IFS= read -r row; do
  service=$(echo "$row" | jq -r '.service')
  quota_metric=$(echo "$row" | jq -r '.quota_metric')
  region=$(echo "$row" | jq -r '.region')
  usage=$(echo "$row" | jq -r '.usage // 0')
  [ -z "$quota_metric" ] && continue

  # Try the authoritative Cloud Quotas API first when available
  limit_value="0"
  quota_info=$(curl -s -H "Authorization: Bearer $token" \
    "https://cloudquotas.googleapis.com/v1/projects/$GCP_PROJECT_ID/locations/global/services/$service/quotaInfos?pageSize=500" 2>/dev/null || echo "{}")
  limit_value=$(echo "$quota_info" | jq -r --arg qm "$quota_metric" '
    [.quotaInfos[]? | select(.metric == $qm or (.metric | endswith($qm))) | .limit // 0] | max // 0' 2>/dev/null || echo "0")

  if [ "$limit_value" = "null" ] || [ -z "$limit_value" ] || python3 -c "import sys; sys.exit(0 if float('$limit_value') <= 0 else 1)" 2>/dev/null; then
    # Fall back to the Service Usage consumerQuotaMetrics values
    metrics_resp=$(curl -s -H "Authorization: Bearer $token" \
      "https://serviceusage.googleapis.com/v1/projects/$GCP_PROJECT_ID/services/$service/consumerQuotaMetrics?view=FULL&pageSize=500" 2>/dev/null || echo "{}")
    limit_value=$(echo "$metrics_resp" | jq -r --arg qm "$quota_metric" '
      [.metrics[]? | select(.metric == $qm or (.metric | endswith($qm))) 
        | .consumerQuotaLimits[]? 
        | [.. | objects | .effectiveLimit? // 0] | max] | max // 0' 2>/dev/null || echo "0")
  fi

  if python3 -c "import sys; sys.exit(0 if float('$limit_value') <= 0 else 1)" 2>/dev/null; then
    continue
  fi

  pct=$(python3 -c "
usage=float('$usage'); limit=float('$limit_value')
print(round(usage/limit*100,2) if limit>0 else 0)
" 2>/dev/null || echo "0")

  if python3 -c "import sys; sys.exit(0 if float('$pct') >= float('$QUOTA_WARNING_THRESHOLD') else 1)" 2>/dev/null; then
    dims=""
    [ -n "$region" ] && dims=" (region: $region)"
    jq -n \
      --arg title "Quota \`$quota_metric\` at/above ${QUOTA_WARNING_THRESHOLD}% for service \`$service\` in project \`$GCP_PROJECT_ID\`" \
      --arg details "Quota \`$quota_metric\`${dims} for service \`$service\` is currently at ${pct}% of its limit (usage ${usage}, limit ${limit_value}). Exceeds the configured warning threshold of ${QUOTA_WARNING_THRESHOLD}%." \
      --arg expected "Quota usage should remain below the ${QUOTA_WARNING_THRESHOLD}% warning threshold" \
      --arg actual "Quota \`$quota_metric\` is at ${pct}% (usage ${usage} of limit ${limit_value})" \
      --arg severity "3" \
      --arg next_steps "Review this quota for service $service. If usage is expected to keep growing, request a limit increase via the Cloud Quotas page or reduce consumption." \
      '{title:$title,details:$details,expected:$expected,actual:$actual,severity:($severity|tonumber),next_steps:$next_steps}' >> "$ISSUES_TMP"
  fi
done

if [ -s "$ISSUES_TMP" ]; then
  jq -s '.' "$ISSUES_TMP" > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Quota threshold analysis completed: $(jq length "$OUTPUT_FILE") issue(s)."

echo ""
echo "=== LLM Context ==="
echo "Project: $GCP_PROJECT_ID"
echo "Quota warning threshold: ${QUOTA_WARNING_THRESHOLD}%"
echo "Cloud Quotas console: https://console.cloud.google.com/quotas?project=$GCP_PROJECT_ID"
