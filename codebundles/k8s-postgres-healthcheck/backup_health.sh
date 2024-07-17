#!/bin/bash

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

# Check the backup based on API version
if [[ "$OBJECT_API_VERSION" == *"crunchydata.com"* ]]; then
  check_crunchy_backup
elif [[ "$OBJECT_API_VERSION" == *"zalan.do"* ]]; then
  check_zalando_backup
else
  echo "Unsupported API version: $OBJECT_API_VERSION. Please specify a valid API version containing 'postgres-operator.crunchydata.com' or 'acid.zalan.do'."
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
