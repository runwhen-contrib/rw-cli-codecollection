#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# OPTIONAL ENV VARS:
#   PITR_MINIMUM_DAYS  (default 1) -- minimum recommended point-in-time-recovery
#                                      retention window, in days
#
# This script:
#   1) Lists all Cloud Spanner instances, then databases within each instance
#   2) Describes each database and reads its version_retention_period
#      (e.g. "1h", "7d") -- Spanner's PITR window
#   3) Parses the duration and flags databases below PITR_MINIMUM_DAYS
#   4) Outputs a JSON array of issues to OUTPUT_FILE
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${PITR_MINIMUM_DAYS:=1}"

OUTPUT_FILE="pitr_config_issues.json"

echo "Checking Cloud Spanner PITR configuration for project: $GCP_PROJECT_ID"

instances=$(gcloud spanner instances list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
instance_count=$(echo "$instances" | jq 'length')

if [ "$instance_count" -eq 0 ]; then
  echo "No Cloud Spanner instances found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> /tmp/pitr_config_parts.jsonl

echo "$instances" | jq -c '.[]' | while read -r inst; do
  instance_id=$(echo "$inst" | jq -r '.name' | awk -F/ '{print $NF}')

  databases=$(gcloud spanner databases list --instance="$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")

  echo "$databases" | jq -c '.[]' | while read -r db; do
    db_name=$(echo "$db" | jq -r '.name' | awk -F/ '{print $NF}')

    db_detail=$(gcloud spanner databases describe "$db_name" --instance="$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "{}")
    vrp=$(echo "$db_detail" | jq -r '.versionRetentionPeriod // "1h"')

    vrp_days=$(python3 -c "
import re
s = '$vrp'.strip()
m = re.match(r'^(\d+(?:\.\d+)?)([a-zA-Z]+)\$', s)
if not m:
    print(-1)
else:
    val = float(m.group(1))
    unit = m.group(2)
    factors = {'s': 1/86400.0, 'm': 1/1440.0, 'h': 1/24.0, 'd': 1.0}
    print(round(val * factors.get(unit, -1), 4) if unit in factors else -1)
" 2>/dev/null || echo "-1")

    if [ "$vrp_days" = "-1" ]; then
      echo "Could not parse version_retention_period '$vrp' for database $db_name, skipping."
      continue
    fi

    below_minimum=$(python3 -c "print('true' if float('$vrp_days') < float('$PITR_MINIMUM_DAYS') else 'false')" 2>/dev/null || echo "false")

    if [ "$below_minimum" = "true" ]; then
      printf '{"title":"Cloud Spanner database `%s` PITR window below minimum (instance `%s`)","details":"Database `%s` on instance `%s` in project `%s` has version_retention_period `%s` (~%s day(s)), below the recommended minimum of %s day(s). A shorter PITR window reduces the range of recoverable timestamps for accidental writes or deletes.","severity":3,"expected":"version_retention_period should be at least %s day(s)","actual":"version_retention_period is `%s` (~%s day(s))","next_steps":"Increase the PITR window via `gcloud spanner databases update %s --instance=%s --project=%s --version-retention-period=%sd`, noting this may increase storage cost.","instance":"%s","database":"%s"}\n' \
        "$db_name" "$instance_id" "$db_name" "$instance_id" "$GCP_PROJECT_ID" "$vrp" "$vrp_days" "$PITR_MINIMUM_DAYS" "$PITR_MINIMUM_DAYS" "$vrp" "$vrp_days" "$db_name" "$instance_id" "$GCP_PROJECT_ID" "$PITR_MINIMUM_DAYS" "$instance_id" "$db_name" >> /tmp/pitr_config_parts.jsonl
    fi
  done
done

if [ -s /tmp/pitr_config_parts.jsonl ]; then
  jq -s '.' /tmp/pitr_config_parts.jsonl > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi
rm -f /tmp/pitr_config_parts.jsonl

echo "PITR configuration check completed. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
