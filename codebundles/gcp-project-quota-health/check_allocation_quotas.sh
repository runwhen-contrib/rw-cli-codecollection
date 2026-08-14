#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# OPTIONAL ENV VARS:
#   SERVICES                 Comma-separated service names to check; 'All' checks all enabled services
#   QUOTA_WARNING_THRESHOLD  Usage percentage of a quota limit that triggers an issue (0-100)
#
# This script enumerates consumer allocation quota metrics for each enabled
# service via the Service Usage API, obtains usage from Cloud Monitoring, and
# raises issues for allocation quotas at or near consumption of their limit.
# Outputs a JSON array of issues to allocation_quota_issues.json
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${SERVICES:=All}"
: "${QUOTA_WARNING_THRESHOLD:=80}"

OUTPUT_FILE="allocation_quota_issues.json"
ISSUES_TMP="$(mktemp)"
trap 'rm -f "$ISSUES_TMP"' EXIT

echo "Checking allocation quota usage vs limit for project: $GCP_PROJECT_ID"

token=$(gcloud auth print-access-token 2>/dev/null || echo "")
if [ -z "$token" ]; then
  echo "Unable to obtain an access token; no allocation quota checked."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

# -----------------------------------------------------------------------------
# 1. Enumerate enabled services via the Service Usage API
# -----------------------------------------------------------------------------
services_json=$(curl -s -H "Authorization: Bearer $token" \
  "https://serviceusage.googleapis.com/v1/projects/$GCP_PROJECT_ID/services?filter=state%3AENABLED&pageSize=200" 2>/dev/null || echo "{}")

if ! echo "$services_json" | jq -e '.services' >/dev/null 2>&1; then
  echo "Service Usage API did not return services (may be disabled or insufficient permission)."
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

echo "Checking allocation quotas for $(echo "$service_names" | wc -l) enabled service(s)."

# -----------------------------------------------------------------------------
# 2. Fetch allocation usage from Cloud Monitoring
# -----------------------------------------------------------------------------
now_epoch=$(date +%s)
start_epoch=$((now_epoch - 3600))

allocation_usage=$(curl -s -H "Authorization: Bearer $token" \
  "https://monitoring.googleapis.com/v3/projects/$GCP_PROJECT_ID/timeSeries?filter=metric.type%3D%22serviceruntime.googleapis.com%2Fquota%2Fallocation%2Fusage%22&interval.startTime=${start_epoch}s&interval.endTime=${now_epoch}s&view=FULL&pageSize=1000" 2>/dev/null || echo "{}")

# Build a lookup: <quota_metric>|<service>|<region> -> latest usage
usage_lookup=$(echo "$allocation_usage" | jq -c '
  [.timeSeries[]? |
    {
      quota_metric: (.metric.labels.quota_metric // .metric.type),
      service: (.resource.labels.service // "unknown"),
      region: (.metric.labels.quota_location // .resource.labels.location // ""),
      usage: ([.points[].value.doubleValue // 0] | max // 0)
    }] 
  | map({key: (.quota_metric + "|" + .service + "|" + .region), value: .usage})
  | group_by(.key) | map({key: .[0].key, value: (map(.value) | max)})
  | from_entries' 2>/dev/null || echo "{}")

> "$ISSUES_TMP"

# -----------------------------------------------------------------------------
# 3. Iterate services and their allocation quota metrics/limits
# -----------------------------------------------------------------------------
while IFS= read -r service; do
  [ -z "$service" ] && continue
  metrics_json=$(curl -s -H "Authorization: Bearer $token" \
    "https://serviceusage.googleapis.com/v1/projects/$GCP_PROJECT_ID/services/$service/consumerQuotaMetrics?view=FULL&pageSize=500" 2>/dev/null || echo "{}")

  if ! echo "$metrics_json" | jq -e '.metrics' >/dev/null 2>&1; then
    continue
  fi

  echo "$metrics_json" | jq -c '.metrics[]?' | while IFS= read -r metric; do
    quota_metric=$(echo "$metric" | jq -r '.name | split("/")[-1] // empty')
    [ -z "$quota_metric" ] && continue

    echo "$metric" | jq -c '.consumerQuotaLimits[]?' | while IFS= read -r limit; do
      limit_value=$(echo "$limit" | jq -r '[.. | objects | .effectiveLimit? // 0] | max // 0' 2>/dev/null || echo "0")
      limit_value="${limit_value:-0}"
      dimensions=$(echo "$limit" | jq -c '.dimensions // {}')
      region=$(echo "$dimensions" | jq -r '.region // ""')

      usage=$(echo "$usage_lookup" | jq -r ".\"${quota_metric}|${service}|${region}\" // 0" 2>/dev/null || echo "0")

      if [ "$limit_value" = "0" ] || [ "$limit_value" = "null" ] || [ -z "$limit_value" ]; then
        continue
      fi

      pct=$(python3 -c "
usage=float('$usage')
limit=float('$limit_value')
print(round(usage/limit*100,2) if limit>0 else 0)
" 2>/dev/null || echo "0")

      if python3 -c "import sys; sys.exit(0 if float('$pct') >= float('$QUOTA_WARNING_THRESHOLD') else 1)" 2>/dev/null; then
        if python3 -c "import sys; sys.exit(0 if float('$pct') >= 95 else 1)" 2>/dev/null; then
          severity="4"
        else
          severity="3"
        fi
        dims=""
        [ -n "$region" ] && dims=" (region: $region)"
        jq -n \
          --arg title "Allocation quota \`$quota_metric\` at ${pct}% for service \`$service\` in project \`$GCP_PROJECT_ID\`" \
          --arg details "Service \`$service\` allocation quota \`$quota_metric\`${dims} is at ${pct}% of its limit (usage ${usage}, limit ${limit_value})." \
          --arg expected "Allocation quota usage should remain below ${QUOTA_WARNING_THRESHOLD}% of the configured limit" \
          --arg actual "Allocation quota is at ${pct}% of limit (usage ${usage} of limit ${limit_value})" \
          --arg severity "$severity" \
          --arg next_steps "Review usage of service $service for quota $quota_metric. Request a quota increase via the Cloud Quotas page, or reduce consumption by adjusting workloads." \
          '{title:$title,details:$details,expected:$expected,actual:$actual,severity:($severity|tonumber),next_steps:$next_steps}' >> "$ISSUES_TMP"
      fi
    done
  done
done <<< "$service_names"

# Combine accumulated single-line issues into a JSON array
if [ -s "$ISSUES_TMP" ]; then
  jq -s '.' "$ISSUES_TMP" > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Allocation quota analysis completed: $(jq length "$OUTPUT_FILE") issue(s)."

echo ""
echo "=== LLM Context ==="
echo "Project: $GCP_PROJECT_ID"
echo "Services checked: $(echo "$service_names" | tr '\n' ',')"
echo "Quota warning threshold: ${QUOTA_WARNING_THRESHOLD}%"
echo "Service Usage console: https://console.cloud.google.com/apis/metrics?project=$GCP_PROJECT_ID"
echo "Cloud Quotas console: https://console.cloud.google.com/quotas?project=$GCP_PROJECT_ID"
