#!/usr/bin/env bash
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${SLOT_UTILIZATION_THRESHOLD:=80}"

OUTPUT_FILE="slot_utilization_issues.json"

echo "Analyzing slot reservation utilization for project: $GCP_PROJECT_ID"

# -----------------------------------------------------------------------------
# Gather purchased slot capacity and usage from the BigQuery Reservation API.
# Reservations may live in a separate admin project; default to the target.
# -----------------------------------------------------------------------------
admin_project="${BIGQUERY_ADMIN_PROJECT:-$GCP_PROJECT_ID}"
location="${BIGQUERY_LOCATION:-US}"

reservation_json=$(gcloud bigquery reservations list \
  --project="$admin_project" \
  --location="$location" \
  --format=json 2>/dev/null || echo "[]")

capacity_slots=0
if [ "$(echo "$reservation_json" | jq length)" -gt 0 ]; then
  capacity_slots=$(echo "$reservation_json" | jq '[.[].slot_capacity // 0] | add')
fi

echo "Total purchased reservation slot capacity: $capacity_slots"

if [ "$capacity_slots" -le 0 ]; then
  echo "No reservations found for project $GCP_PROJECT_ID. Nothing to monitor."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

# -----------------------------------------------------------------------------
# Pull slot utilization via Cloud Monitoring REST API.
# gcloud monitoring time-series list does not exist; query the v3 API directly.
# -----------------------------------------------------------------------------
now_epoch=$(date +%s)
start_epoch=$((now_epoch - 3600))

utilization_pct=0
token=$(gcloud auth print-access-token 2>/dev/null || echo "")
if [ -n "$token" ]; then
  monitor_response=$(curl -s -H "Authorization: Bearer $token" \
    "https://monitoring.googleapis.com/v3/projects/$GCP_PROJECT_ID/timeSeries?filter=metric.type%3D%22bigquery.googleapis.com%2Fslots%2Favailable_capacity%22&interval.startTime=${start_epoch}s&interval.endTime=${now_epoch}s&view=FULL" \
    2>/dev/null || echo "")
  if echo "$monitor_response" | jq -e '.timeSeries' > /dev/null 2>&1; then
    utilization_pct=$(echo "$monitor_response" | jq -r '[.timeSeries[].points[].value.doubleValue // 0] | add / length // 0' 2>/dev/null)
  fi
fi

utilization_pct=${utilization_pct:-0}

if python3 -c "import sys; sys.exit(0 if float('$utilization_pct') > 0 else 1)" 2>/dev/null; then
  # available_capacity is remaining slots; utilization = (1 - available/capacity) * 100
  utilized_slots=$(python3 -c "print(max(0.0, $capacity_slots - $utilization_pct))" 2>/dev/null || echo 0)
  utilization_pct=$(python3 -c "print(round($utilized_slots / $capacity_slots * 100, 2))" 2>/dev/null || echo 0)
else
  echo "No slot utilization data from Cloud Monitoring. Reporting 0% utilized."
  utilization_pct=0
fi

echo "Slot utilization: ${utilization_pct}% (threshold: ${SLOT_UTILIZATION_THRESHOLD}%)"

if python3 -c "import sys; sys.exit(0 if float('$utilization_pct') >= float('$SLOT_UTILIZATION_THRESHOLD') else 1)" 2>/dev/null; then
  if python3 -c "import sys; sys.exit(0 if float('$utilization_pct') >= 95 else 1)" 2>/dev/null; then
    severity="3"
  else
    severity="2"
  fi
  jq -n \
    --arg title "BigQuery slot utilization elevated for project \`$GCP_PROJECT_ID\`" \
    --arg details "BigQuery project \`$GCP_PROJECT_ID\` is at ${utilization_pct}% of its purchased slot capacity (${capacity_slots} slots). Threshold is ${SLOT_UTILIZATION_THRESHOLD}%." \
    --arg expected "Slot utilization should remain below ${SLOT_UTILIZATION_THRESHOLD}% of purchased capacity" \
    --arg actual "Slot utilization is ${utilization_pct}% of ${capacity_slots} purchased slots" \
    --arg severity "$severity" \
    --arg next_steps "Request additional slot capacity from your reservation admin, or optimize queries and reduce concurrent workload to lower slot consumption." \
    '[{title:$title,details:$details,expected:$expected,actual:$actual,severity:($severity|tonumber),next_steps:$next_steps}]' > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Slot utilization analysis completed."

echo ""
echo "=== LLM Context ==="
echo "BigQuery Console: https://console.cloud.google.com/bigquery?project=$GCP_PROJECT_ID"
echo "BigQuery Reservations: https://console.cloud.google.com/bigquery/reservations?project=$admin_project"
echo "Slot Threshold: ${SLOT_UTILIZATION_THRESHOLD}%"
echo "Reservation Capacity: $capacity_slots slots"
echo "Reservation Location: $location"
