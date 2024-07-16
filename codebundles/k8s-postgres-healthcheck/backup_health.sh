#!/bin/bash

# Clean up report file
rm ../backup_report.out || true

# Set the maximum acceptable age of the backup (in seconds) - here it's 1 day (86400 seconds)
MAX_AGE=86400

# Arrays to store backup reports and issues
BACKUP_REPORTS=()
ISSUES=()

# Function to generate an issue in JSON format
generate_issue() {
  cat <<EOF
{
    "title": "Backup health issue for Postgres Cluster `${OBJECT_NAME}` in `${NAMESPACE}`",
    "description": "$1",
    "backup_completion_time": "$2",
    "backup_age_seconds": "$3"
}
EOF
}

# Function to check CrunchyDB PostgreSQL Operator backup
check_crunchy_backup() {
  POSTGRES_CLUSTER=$(${KUBERNETES_DISTRIBUTION_BINARY} describe -n "$NAMESPACE" postgresclusters.postgres-operator.crunchydata.com $OBJECT_NAME --context "$CONTEXT")
  LATEST_BACKUP_TIME=$(echo "$POSTGRES_CLUSTER" | grep -A 5 "Scheduled Backups:" | grep "Completion Time:" | tail -1 | awk '{print $3}')
  LATEST_BACKUP_TIMESTAMP=$(date -d "$LATEST_BACKUP_TIME" +%s)
  CURRENT_TIMESTAMP=$(date +%s)
  BACKUP_AGE=$((CURRENT_TIMESTAMP - LATEST_BACKUP_TIMESTAMP))

  BACKUP_REPORTS+=("CrunchyDB Backup completed at $LATEST_BACKUP_TIME with age $BACKUP_AGE seconds.")

  if [ "$BACKUP_AGE" -gt "$MAX_AGE" ]; then
    ISSUES+=("$(generate_issue "The latest backup for the CrunchyDB PostgreSQL cluster is older than the acceptable limit." "$LATEST_BACKUP_TIME" "$BACKUP_AGE")")
  else
    BACKUP_REPORTS+=("CrunchyDB Backup is healthy. Latest backup completed at $LATEST_BACKUP_TIME.")
  fi
}

# Function to check Zalando PostgreSQL Operator backup
check_zalando_backup() {
  # Assuming that we need to log in to the database to check backup status
  POD_NAME=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" --context "$CONTEXT" -l application=spilo -o jsonpath="{.items[0].metadata.name}")

  LATEST_BACKUP_TIME=$(${KUBERNETES_DISTRIBUTION_BINARY} exec -n "$NAMESPACE" "$POD_NAME" --context "$CONTEXT" -- bash -c 'psql -U postgres -t -c "SELECT MAX(backup_time) FROM pg_stat_archiver;"')
  LATEST_BACKUP_TIMESTAMP=$(date -d "$LATEST_BACKUP_TIME" +%s)
  CURRENT_TIMESTAMP=$(date +%s)
  BACKUP_AGE=$((CURRENT_TIMESTAMP - LATEST_BACKUP_TIMESTAMP))

  BACKUP_REPORTS+=("Zalando Backup completed at $LATEST_BACKUP_TIME with age $BACKUP_AGE seconds.")

  if [ "$BACKUP_AGE" -gt "$MAX_AGE" ]; then
    ISSUES+=("$(generate_issue "The latest backup for the Zalando PostgreSQL cluster is older than the acceptable limit." "$LATEST_BACKUP_TIME" "$BACKUP_AGE")")
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
rm $OUTPUT_FILE

# Print the backup reports and issues
echo "Backup Report:" > "$OUTPUT_FILE"
for report in "${BACKUP_REPORTS[@]}"; do
  echo "$report" >> "$OUTPUT_FILE"
done

echo "" >> ."$OUTPUT_FILE"
echo "Issues:" >> "$OUTPUT_FILE"
echo "[" >> "$OUTPUT_FILE"
for issue in "${ISSUES[@]}"; do
  echo "$issue," >> "$OUTPUT_FILE"
done
# Remove the last comma and close the JSON array
sed -i '$ s/,$//' "$OUTPUT_FILE"
echo "]" >> "$OUTPUT_FILE"
