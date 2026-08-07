#!/usr/bin/env bash
set -euo pipefail
set -x

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
# Pull slot utilization via Cloud Monitoring when available.
# We query peak available capacity relative to purchased capacity.
# -----------------------------------------------------------------------------
now_epoch=$(date +%s)
start_epoch=$((now_epoch - 3600))

utilization_pct=0
if gcloud monitoring time-series list \
  --project="$GCP_PROJECT_ID" \
  --filter="metric.type=bigquery.googleapis.com/slots/available_capacity" \
  --interval-start="$((now_epoch - 3600))" \
  --interval-end="$now_epoch" \
  --format="value(points[0].value.doubleValue)" > /tmp/bq_slots_raw.txt 2>/dev/null; then
  utilization_pct=$(awk '{sum+=$1; n++} END {if (n>0) print sum/n; else print 0}' /tmp/bq_slots_raw.txt)
fi
rm -f /tmp/bq_slots_raw.txt

utilization_pct=${utilization_pct:-0}

if python3 -c "import sys; sys.exit(0 if $utilization_pct > 0 else 1)" 2>/dev/null; then
  # available_capacity is remaining slots; utilization = (1 - available/capacity) * 100
  utilized_slots=$(python3 -c "print(max(0.0, $capacity_slots - $utilization_pct))" 2>/dev/null)
  utilization_pct=$(python3 -c "print(round($utilized_slots / $capacity_slots * 100, 2))" 2>/dev/null || echo 0)
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
jq . "$OUTPUT_FILE"
