#!/bin/bash

if [[ -f spilo_statefulset_helpers.sh ]]; then
  # shellcheck disable=SC1091
  source spilo_statefulset_helpers.sh
fi

# Set the maximum acceptable age of the backup (in seconds) based on BACKUP_MAX_AGE environment variable
MAX_AGE=$((BACKUP_MAX_AGE * 3600))
# Arrays to store backup reports and issues
BACKUP_REPORTS=()
ISSUES=()

# Function to generate an issue in JSON format
generate_issue() {
  cat <<EOF
{
    "title": "Backup health issue for Postgres Cluster \`$OBJECT_NAME\` in \`$NAMESPACE\`",
    "description": "$1",
    "backup_completion_time": "$2",
    "backup_age_hours": "$3"
}
EOF
}

# Function to check CrunchyDB PostgreSQL Operator backup
check_crunchy_backup() {
  POSTGRES_CLUSTER_JSON=$(${KUBERNETES_DISTRIBUTION_BINARY} get postgresclusters.postgres-operator.crunchydata.com $OBJECT_NAME -n "$NAMESPACE" --context "$CONTEXT" -o json)
  LATEST_BACKUP_TIME=$(echo "$POSTGRES_CLUSTER_JSON" | jq -r '.status.pgbackrest.scheduledBackups | max_by(.completionTime) | .completionTime')
  
  LATEST_BACKUP_TIMESTAMP=$(date -d "$LATEST_BACKUP_TIME" +%s)
  CURRENT_TIMESTAMP=$(date +%s)
  BACKUP_AGE=$((CURRENT_TIMESTAMP - LATEST_BACKUP_TIMESTAMP))
  BACKUP_AGE_HOURS=$(awk "BEGIN {print $BACKUP_AGE/3600}")

  BACKUP_REPORTS+=("CrunchyDB Backup completed at $LATEST_BACKUP_TIME with age $BACKUP_AGE_HOURS hours.")

  if [ "$BACKUP_AGE" -gt "$MAX_AGE" ]; then
    ISSUES+=("$(generate_issue "The latest backup for the CrunchyDB PostgreSQL cluster \`$OBJECT_NAME\` is older than the acceptable limit of $BACKUP_MAX_AGE hour(s)." "$LATEST_BACKUP_TIME" "$BACKUP_AGE_HOURS")")
  else
    BACKUP_REPORTS+=("CrunchyDB Backup is healthy. Latest backup completed at $LATEST_BACKUP_TIME.")
  fi
}

# Function to check Zalando PostgreSQL Operator backup
check_zalando_backup() {
  # Assuming that we need to log in to the database to check backup status
  POD_NAME=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" --context "$CONTEXT" -l application=spilo -o jsonpath="{.items[0].metadata.name}")

  LATEST_BACKUP_TIME=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$POD_NAME" --context "$CONTEXT" -c "$DATABASE_CONTAINER" -- bash -c 'psql -U postgres -t -c "SELECT MAX(backup_time) FROM pg_stat_archiver;"')
  LATEST_BACKUP_TIMESTAMP=$(date -d "$LATEST_BACKUP_TIME" +%s)
  CURRENT_TIMESTAMP=$(date +%s)
  BACKUP_AGE=$((CURRENT_TIMESTAMP - LATEST_BACKUP_TIMESTAMP))
  BACKUP_AGE_HOURS=$(awk "BEGIN {print $BACKUP_AGE/3600}")

  BACKUP_REPORTS+=("Zalando Backup completed at $LATEST_BACKUP_TIME with age $BACKUP_AGE_HOURS hours.")

  if [ "$BACKUP_AGE" -gt "$MAX_AGE" ]; then
    ISSUES+=("$(generate_issue "The latest backup for the Zalando PostgreSQL cluster is older than the acceptable limit of $BACKUP_MAX_AGE hour(s)." "$LATEST_BACKUP_TIME" "$BACKUP_AGE_HOURS")")
  else
    BACKUP_REPORTS+=("Zalando Backup is healthy. Latest backup completed at $LATEST_BACKUP_TIME.")
  fi
}

# Function to check bare Spilo StatefulSet backup via WAL-G or pg_stat_archiver
check_spilo_statefulset_backup() {
  local pod_info
  pod_info=$(find_spilo_statefulset_pod "false")
  POD_NAME=$(echo "$pod_info" | cut -d'|' -f1)
  local container
  container=$(echo "$pod_info" | cut -d'|' -f2)

  if [[ -z "$POD_NAME" ]]; then
    BACKUP_REPORTS+=("No running Spilo pods found for StatefulSet \`$OBJECT_NAME\` in \`$NAMESPACE\`.")
    ISSUES+=("$(generate_issue "No running Spilo pods found for StatefulSet \`$OBJECT_NAME\` in \`$NAMESPACE\`." "" "")")
    return
  fi

  local use_walg backup_reference=""
  use_walg=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$POD_NAME" --context "$CONTEXT" -c "$container" \
    -- bash -c 'echo "${USE_WALG_BACKUP:-false}"' 2>/dev/null | tr -d '[:space:]')

  if [[ "$use_walg" == "true" ]]; then
    local walg_line walg_time
    walg_line=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$POD_NAME" --context "$CONTEXT" -c "$container" \
      -- bash -c 'wal-g backup-list 2>/dev/null | tail -1' 2>/dev/null | tr -d '\r')
    if [[ -z "$walg_line" || "$walg_line" == *"No backups"* ]]; then
      BACKUP_REPORTS+=("WAL-G is enabled but no backups were found via wal-g backup-list on pod \`$POD_NAME\`.")
      ISSUES+=("$(generate_issue "No WAL-G backups found for Spilo StatefulSet \`$OBJECT_NAME\` in \`$NAMESPACE\`." "" "")")
      return
    fi
    walg_time=$(echo "$walg_line" | awk '{for (i=2; i<=NF; i++) if ($i ~ /^[0-9T:-]+$/) {print $i; exit}}')
    if [[ -z "$walg_time" ]]; then
      walg_time=$(echo "$walg_line" | awk '{print $(NF-1)" "$NF}')
    fi
    backup_reference="$walg_line"
    LATEST_BACKUP_TIMESTAMP=$(date -d "$walg_time" +%s 2>/dev/null || date -d "$(echo "$walg_line" | awk '{print $2, $3}')" +%s 2>/dev/null || echo 0)
    if [[ "$LATEST_BACKUP_TIMESTAMP" == "0" ]]; then
      BACKUP_REPORTS+=("WAL-G backup-list on pod \`$POD_NAME\`: $walg_line")
      BACKUP_REPORTS+=("Could not parse WAL-G backup timestamp; see backup-list output above.")
      ISSUES+=("$(generate_issue "Could not parse WAL-G backup timestamp for Spilo StatefulSet \`$OBJECT_NAME\` in \`$NAMESPACE\`." "$walg_line" "")")
      return
    fi
    CURRENT_TIMESTAMP=$(date +%s)
    BACKUP_AGE=$((CURRENT_TIMESTAMP - LATEST_BACKUP_TIMESTAMP))
    BACKUP_AGE_HOURS=$(awk "BEGIN {print $BACKUP_AGE/3600}")
    BACKUP_REPORTS+=("WAL-G backup (USE_WALG_BACKUP=true) latest entry: $walg_line (age ${BACKUP_AGE_HOURS} hours).")
  else
    local LATEST_BACKUP_TIME
    LATEST_BACKUP_TIME=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$POD_NAME" --context "$CONTEXT" -c "$container" -- bash -c 'psql -U postgres -t -c "SELECT MAX(backup_time) FROM pg_stat_archiver;"' 2>/dev/null | tr -d '[:space:]')
    if [[ -z "$LATEST_BACKUP_TIME" || "$LATEST_BACKUP_TIME" == "" ]]; then
      BACKUP_REPORTS+=("pg_stat_archiver returned no backup_time on pod \`$POD_NAME\` (archive_mode may be off).")
      ISSUES+=("$(generate_issue "No archive backup_time found for Spilo StatefulSet \`$OBJECT_NAME\` in \`$NAMESPACE\`. pg_stat_archiver returned empty (archive_mode may be off)." "" "")")
      return
    fi
    backup_reference="$LATEST_BACKUP_TIME"
    LATEST_BACKUP_TIMESTAMP=$(date -d "$LATEST_BACKUP_TIME" +%s 2>/dev/null || echo 0)
    if [[ -z "$LATEST_BACKUP_TIMESTAMP" || "$LATEST_BACKUP_TIMESTAMP" == "0" ]]; then
      BACKUP_REPORTS+=("Could not parse archive backup_time \`$LATEST_BACKUP_TIME\` from pg_stat_archiver on pod \`$POD_NAME\`.")
      ISSUES+=("$(generate_issue "Could not parse archive backup_time for Spilo StatefulSet \`$OBJECT_NAME\` in \`$NAMESPACE\`." "$LATEST_BACKUP_TIME" "")")
      return
    fi
    CURRENT_TIMESTAMP=$(date +%s)
    BACKUP_AGE=$((CURRENT_TIMESTAMP - LATEST_BACKUP_TIMESTAMP))
    BACKUP_AGE_HOURS=$(awk "BEGIN {print $BACKUP_AGE/3600}")
    BACKUP_REPORTS+=("Spilo StatefulSet archive backup completed at $LATEST_BACKUP_TIME with age $BACKUP_AGE_HOURS hours.")
  fi

  if [ "$BACKUP_AGE" -gt "$MAX_AGE" ]; then
    ISSUES+=("$(generate_issue "The latest backup for Spilo StatefulSet \`$OBJECT_NAME\` is older than the acceptable limit of $BACKUP_MAX_AGE hour(s)." "$backup_reference" "$BACKUP_AGE_HOURS")")
  else
    BACKUP_REPORTS+=("Spilo StatefulSet backup is healthy.")
  fi
}

# Check the backup based on API version
if [[ "$OBJECT_API_VERSION" == *"crunchydata.com"* ]]; then
  check_crunchy_backup
elif [[ "$OBJECT_API_VERSION" == *"zalan.do"* ]]; then
  check_zalando_backup
elif is_spilo_statefulset 2>/dev/null; then
  check_spilo_statefulset_backup
else
  echo "Unsupported API version: $OBJECT_API_VERSION. Please specify a valid API version containing 'postgres-operator.crunchydata.com', 'acid.zalan.do', or set OBJECT_KIND to statefulset for bare Spilo deployments."
fi

OUTPUT_FILE="../backup_report.out"
rm -f $OUTPUT_FILE

# Print the backup reports and issues
echo "Backup Report:" > "$OUTPUT_FILE"
echo "Maximum age for last backup is set to: $BACKUP_MAX_AGE hour(s)"  >> "$OUTPUT_FILE"
for report in "${BACKUP_REPORTS[@]}"; do
  echo "$report" >> "$OUTPUT_FILE"
done

echo "" >> "$OUTPUT_FILE"
echo "Issues:" >> "$OUTPUT_FILE"
echo "[" >> "$OUTPUT_FILE"
for issue in "${ISSUES[@]}"; do
  echo "$issue," >> "$OUTPUT_FILE"
done
# Remove the last comma and close the JSON array
sed -i '$ s/,$//' "$OUTPUT_FILE"
echo "]" >> "$OUTPUT_FILE"
