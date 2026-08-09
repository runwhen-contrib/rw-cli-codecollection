#!/usr/bin/env bash
set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
# OPTIONAL ENV VARS:
#   RESOURCES                        (comma-separated instance name filter; "All")
#   CONFIG_IMPORTANCE_THRESHOLD      (min vCPU count considered healthy, default 2)
#
# This script dumps each instance's configuration (tier, disk, region, zones,
# database version, maintenance window, backup settings) and flags risky
# configuration such as an undersized tier, disabled automated backups, or
# disabled point-in-time recovery.
# It writes a JSON array of issues to instance_config_issues.json.
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${RESOURCES:=All}"
: "${CONFIG_IMPORTANCE_THRESHOLD:=2}"

OUTPUT_FILE="instance_config_issues.json"

echo "Fetching Cloud SQL instance configuration for project: $GCP_PROJECT_ID"

parse_vcpu() {
  local tier="$1"
  case "$tier" in
    db-custom-*) echo "$tier" | sed -E 's/db-custom-([0-9]+)-[0-9]+/\1/' ;;
    db-n*-standard-*) echo "$tier" | sed -E 's/db-n[0-9]+-standard-([0-9]+)/\1/' ;;
    db-n*-highmem-*) echo "$tier" | sed -E 's/db-n[0-9]+-highmem-([0-9]+)/\1/' ;;
    db-n*-highcpu-*) echo "$tier" | sed -E 's/db-n[0-9]+-highcpu-([0-9]+)/\1/' ;;
    db-f1-micro|db-g1-small) echo "1" ;;
    *) echo "999" ;;
  esac
}

instances=$(gcloud sql instances list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
if [ "$(echo "$instances" | jq length)" -eq 0 ]; then
  echo "No Cloud SQL instances found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

if [ "$RESOURCES" != "All" ] && [ -n "$RESOURCES" ]; then
  filter=$(echo "$RESOURCES" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | paste -sd'|' -)
  if [ -z "$filter" ]; then
    filter="NEVER_MATCHES"
  fi
  instances=$(echo "$instances" | jq --arg f "$filter" '[.[] | select(.name | test($f))]')
fi

if [ "$(echo "$instances" | jq length)" -eq 0 ]; then
  echo "No matching instances found."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> "$OUTPUT_FILE"

echo "$instances" | jq -c '.[]' | while read -r inst; do
  name=$(echo "$inst" | jq -r '.name // "unknown"')

  echo "Fetching configuration for $name"
  cfg=$(gcloud sql instances describe "$name" --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "{}")

  tier=$(echo "$cfg" | jq -r '.settings.tier // ""')
  vcpu=$(parse_vcpu "$tier" 2>/dev/null || echo "999")
  data_disk_gb=$(echo "$cfg" | jq -r '.settings.dataDiskSizeGb // 0')
  region=$(echo "$cfg" | jq -r '.region // ""')
  database_version=$(echo "$cfg" | jq -r '.databaseVersion // ""')
  maintenance=$(echo "$cfg" | jq -c '{day: .settings.maintenanceWindow.day, hour: .settings.maintenanceWindow.hour}')
  backup_enabled=$(echo "$cfg" | jq -r '.settings.backupConfiguration.enabled // false')

  # Point-in-time recovery is represented differently per engine:
  #   * MySQL            -> settings.backupConfiguration.binaryLogEnabled
  #   * Postgres/SQLServer -> settings.backupConfiguration.pointInTimeRecoveryEnabled
  db_upper=$(echo "$database_version" | tr '[:lower:]' '[:upper:]')
  if [[ "$db_upper" == MYSQL* ]]; then
    pitr_enabled=$(echo "$cfg" | jq -r '.settings.backupConfiguration.binaryLogEnabled // false')
  else
    pitr_enabled=$(echo "$cfg" | jq -r '.settings.backupConfiguration.pointInTimeRecoveryEnabled // false')
  fi

  echo "  $name tier=$tier vcpu=$vcpu db=$database_version backup=$backup_enabled pitr=$pitr_enabled"

  if [ "$vcpu" != "999" ] && [ "$vcpu" -lt "$CONFIG_IMPORTANCE_THRESHOLD" ]; then
    printf '{"title":"Cloud SQL instance `%s` uses an undersized tier","details":"Cloud SQL instance `%s` in project `%s` uses tier `%s` (%s vCPU) which is below the configured importance threshold of %s vCPU.","severity":2,"expected":"Instance tier should provide at least %s vCPU","actual":"Instance tier `%s` provides %s vCPU","next_steps":"Consider upgrading the instance to a larger tier to avoid capacity limits. See: gcloud sql instances patch %s --tier=<larger-tier> --project=%s.","instance":"%s","tier":"%s","issue_type":"undersized_tier"}\n' \
      "$name" "$name" "$GCP_PROJECT_ID" "$tier" "$vcpu" "$CONFIG_IMPORTANCE_THRESHOLD" "$CONFIG_IMPORTANCE_THRESHOLD" "$tier" "$vcpu" "$name" "$GCP_PROJECT_ID" "$name" "$tier" >> "$OUTPUT_FILE"
  fi

  if [ "$backup_enabled" != "true" ]; then
    printf '{"title":"Cloud SQL instance `%s` has automated backups disabled","details":"Cloud SQL instance `%s` in project `%s` does not have automated backups enabled. Point-in-time recovery is unavailable.","severity":2,"expected":"Automated backups should be enabled","actual":"Automated backups are disabled","next_steps":"Enable automated backups: gcloud sql instances patch %s --backup-start-time=02:00 --project=%s.","instance":"%s","issue_type":"backups_disabled"}\n' \
      "$name" "$name" "$GCP_PROJECT_ID" "$name" "$GCP_PROJECT_ID" "$name" >> "$OUTPUT_FILE"
  fi

  if [ "$pitr_enabled" != "true" ]; then
    printf '{"title":"Cloud SQL instance `%s` has point-in-time recovery disabled","details":"Cloud SQL instance `%s` in project `%s` does not have point-in-time recovery (PITR) enabled, limiting recovery granularity.","severity":2,"expected":"Point-in-time recovery should be enabled","actual":"Point-in-time recovery is disabled","next_steps":"Enable PITR. MySQL: gcloud sql instances patch %s --enable-bin-log --project=%s. Postgres/SQL Server: gcloud sql instances patch %s --enable-point-in-time-recovery --project=%s.","instance":"%s","issue_type":"pitr_disabled"}\n' \
      "$name" "$name" "$GCP_PROJECT_ID" "$name" "$GCP_PROJECT_ID" "$name" "$GCP_PROJECT_ID" "$name" >> "$OUTPUT_FILE"
  fi

  # Print a human-readable summary line per instance.
  echo "  Config summary: tier=$tier disk=${data_disk_gb}GB region=$region db=$database_version maintenance=$maintenance"
done

if [ -s "$OUTPUT_FILE" ]; then
  jq -s '.' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Config check complete. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
