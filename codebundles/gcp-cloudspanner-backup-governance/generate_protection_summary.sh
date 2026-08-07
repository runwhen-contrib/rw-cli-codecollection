#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# OPTIONAL ENV VARS:
#   BACKUP_RECENCY_THRESHOLD_HOURS  (default 24)
#   PITR_MINIMUM_DAYS               (default 1)
#   REQUIRE_CMEK                    (default false)
#
# This script:
#   1) Lists all Cloud Spanner instances, then databases within each instance
#   2) Produces a consolidated per-database JSON summary of backup recency,
#      PITR window, deletion protection, IAM exposure, and encryption, with
#      an overall verdict (healthy/warning/critical)
#   3) Writes the summary to SUMMARY_FILE
#   4) Also writes a JSON array of issues (one per non-healthy database) to
#      OUTPUT_FILE so the runbook can surface a rollup issue
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${BACKUP_RECENCY_THRESHOLD_HOURS:=24}"
: "${PITR_MINIMUM_DAYS:=1}"
: "${REQUIRE_CMEK:=false}"

SUMMARY_FILE="protection_summary.json"
OUTPUT_FILE="protection_summary_issues.json"

echo "Generating Cloud Spanner data protection summary for project: $GCP_PROJECT_ID"

instances=$(gcloud spanner instances list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
instance_count=$(echo "$instances" | jq 'length')

if [ "$instance_count" -eq 0 ]; then
  echo "No Cloud Spanner instances found."
  printf '{"project_id":"%s","total_databases":0,"databases":[]}\n' "$GCP_PROJECT_ID" > "$SUMMARY_FILE"
  echo "[]" > "$OUTPUT_FILE"
  jq . "$SUMMARY_FILE"
  exit 0
fi

> /tmp/protection_summary_databases.jsonl
> /tmp/protection_summary_issues.jsonl

echo "$instances" | jq -c '.[]' | while read -r inst; do
  instance_id=$(echo "$inst" | jq -r '.name' | awk -F/ '{print $NF}')

  instance_detail=$(gcloud spanner instances describe "$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "{}")
  instance_drop_protection="unknown"
  if [ "$(echo "$instance_detail" | jq -r 'has("enableDropProtection")')" = "true" ]; then
    instance_drop_protection=$(echo "$instance_detail" | jq -r '.enableDropProtection')
  fi

  instance_iam=$(gcloud spanner instances get-iam-policy "$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "{}")
  instance_public=$(echo "$instance_iam" | jq -r '[.bindings[]?.members[]? | select(. == "allUsers" or . == "allAuthenticatedUsers")] | length > 0')

  databases=$(gcloud spanner databases list --instance="$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
  backups=$(gcloud spanner backups list --instance="$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")

  echo "$databases" | jq -c '.[]' | while read -r db; do
    db_name=$(echo "$db" | jq -r '.name' | awk -F/ '{print $NF}')
    db_full_name=$(echo "$db" | jq -r '.name')

    db_detail=$(gcloud spanner databases describe "$db_name" --instance="$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "{}")
    db_drop_protection=$(echo "$db_detail" | jq -r '.enableDropProtection // false')
    kms_key=$(echo "$db_detail" | jq -r '.encryptionConfig.kmsKeyName // empty')
    has_cmek="false"
    [ -n "$kms_key" ] && has_cmek="true"

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

    latest_backup_time=$(echo "$backups" | jq -r --arg db "$db_full_name" \
      '[.[] | select(.database == $db)] | sort_by(.createTime) | last | .createTime // empty')
    has_backup="false"
    backup_age_hours="null"
    if [ -n "$latest_backup_time" ]; then
      has_backup="true"
      backup_age_hours=$(python3 -c "
import datetime
try:
    t = '$latest_backup_time'.split('.')[0].replace('Z','')
    st = datetime.datetime.strptime(t, '%Y-%m-%dT%H:%M:%S')
    now = datetime.datetime.utcnow()
    print(f'{(now - st).total_seconds() / 3600:.1f}')
except Exception:
    print('null')
" 2>/dev/null || echo "null")
    fi

    db_iam=$(gcloud spanner databases get-iam-policy "$db_name" --instance="$instance_id" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "{}")
    db_public=$(echo "$db_iam" | jq -r '[.bindings[]?.members[]? | select(. == "allUsers" or . == "allAuthenticatedUsers")] | length > 0')

    # --- Determine verdict ---
    verdict="healthy"
    reasons=()

    if [ "$has_backup" = "false" ]; then
      verdict="critical"
      reasons+=("no backup exists")
    elif [ "$backup_age_hours" != "null" ] && python3 -c "exit(0 if float('$backup_age_hours') > float('$BACKUP_RECENCY_THRESHOLD_HOURS') else 1)" 2>/dev/null; then
      [ "$verdict" = "healthy" ] && verdict="warning"
      reasons+=("most recent backup is ${backup_age_hours}h old")
    fi

    if [ "$db_public" = "true" ] || [ "$instance_public" = "true" ]; then
      verdict="critical"
      reasons+=("public IAM binding present")
    fi

    if [ "$db_drop_protection" = "false" ]; then
      [ "$verdict" = "healthy" ] && verdict="warning"
      reasons+=("database deletion protection disabled")
    fi
    if [ "$instance_drop_protection" = "false" ]; then
      [ "$verdict" = "healthy" ] && verdict="warning"
      reasons+=("instance deletion protection disabled")
    fi

    if [ "$vrp_days" != "-1" ] && python3 -c "exit(0 if float('$vrp_days') < float('$PITR_MINIMUM_DAYS') else 1)" 2>/dev/null; then
      [ "$verdict" = "healthy" ] && verdict="warning"
      reasons+=("PITR window ~${vrp_days}d below ${PITR_MINIMUM_DAYS}d minimum")
    fi

    if [ "$REQUIRE_CMEK" = "true" ] && [ "$has_cmek" = "false" ]; then
      [ "$verdict" = "healthy" ] && verdict="warning"
      reasons+=("CMEK required but not configured")
    fi

    reasons_json=$(printf '%s\n' "${reasons[@]:-}" | jq -R . | jq -s 'map(select(length > 0))')

    db_summary=$(jq -n \
      --arg instance "$instance_id" \
      --arg database "$db_name" \
      --argjson has_backup "$has_backup" \
      --arg backup_age_hours "$backup_age_hours" \
      --argjson pitr_days "${vrp_days/-1/null}" \
      --argjson instance_deletion_protection "$([ "$instance_drop_protection" = "unknown" ] && echo null || echo "$instance_drop_protection")" \
      --argjson database_deletion_protection "$db_drop_protection" \
      --argjson public_iam_binding "$([ "$db_public" = "true" ] || [ "$instance_public" = "true" ] && echo true || echo false)" \
      --argjson cmek_enabled "$has_cmek" \
      --arg verdict "$verdict" \
      --argjson reasons "$reasons_json" \
      '{
        "instance": $instance,
        "database": $database,
        "has_backup": $has_backup,
        "backup_age_hours": (if $backup_age_hours == "null" then null else ($backup_age_hours | tonumber) end),
        "pitr_days": $pitr_days,
        "instance_deletion_protection": $instance_deletion_protection,
        "database_deletion_protection": $database_deletion_protection,
        "public_iam_binding": $public_iam_binding,
        "cmek_enabled": $cmek_enabled,
        "verdict": $verdict,
        "reasons": $reasons
      }')

    echo "$db_summary" >> /tmp/protection_summary_databases.jsonl

    if [ "$verdict" != "healthy" ]; then
      reasons_text=$(echo "$reasons_json" | jq -r 'join("; ")')
      severity=3
      printf '{"title":"Cloud Spanner database `%s` data protection verdict: %s (instance `%s`)","details":"Database `%s` on instance `%s` in project `%s` rolled up to verdict %s. Reasons: %s.","severity":%s,"expected":"Database should have a healthy data-protection verdict across backup, PITR, deletion protection, IAM, and encryption dimensions","actual":"Verdict is %s (%s)","next_steps":"Review the detailed backup-recency, PITR, deletion-protection, IAM-access, and encryption task results for `%s` and remediate the flagged dimension(s).","instance":"%s","database":"%s"}\n' \
        "$db_name" "$verdict" "$instance_id" "$db_name" "$instance_id" "$GCP_PROJECT_ID" "$verdict" "$reasons_text" "$severity" "$verdict" "$reasons_text" "$db_name" "$instance_id" "$db_name" >> /tmp/protection_summary_issues.jsonl
    fi
  done
done

if [ -s /tmp/protection_summary_databases.jsonl ]; then
  databases_json=$(jq -s '.' /tmp/protection_summary_databases.jsonl)
else
  databases_json="[]"
fi
total_databases=$(echo "$databases_json" | jq 'length')

jq -n \
  --arg project_id "$GCP_PROJECT_ID" \
  --argjson total_databases "$total_databases" \
  --argjson databases "$databases_json" \
  '{
    "project_id": $project_id,
    "total_databases": $total_databases,
    "databases": $databases
  }' > "$SUMMARY_FILE"

if [ -s /tmp/protection_summary_issues.jsonl ]; then
  jq -s '.' /tmp/protection_summary_issues.jsonl > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi
rm -f /tmp/protection_summary_databases.jsonl /tmp/protection_summary_issues.jsonl

echo "Protection summary generated. $(jq length "$OUTPUT_FILE") database(s) flagged."
jq . "$SUMMARY_FILE"
