#!/usr/bin/env bash
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="audit_logging_issues.json"
issues_json='[]'

echo "Checking audit logging configuration for project: $GCP_PROJECT_ID"

# Check if Data Access audit logs are configured for BigQuery
audit_config=$(gcloud projects get-iam-policy "$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "{}")
# Also check audit logging config via Cloud Logging
log_sinks=$(gcloud logging sinks list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")

# Check for BigQuery-related log sinks
bq_sinks=$(echo "$log_sinks" | jq '[.[] | select(.filter | test("bigquery|BigQuery", "i"))]')
bq_sink_count=$(echo "$bq_sinks" | jq length)

if [ "$bq_sink_count" -eq 0 ]; then
  echo "No BigQuery-specific log sinks found. Checking project-level audit config..."

  # Check if there's a broader sink that captures BigQuery logs
  all_sinks=$(echo "$log_sinks" | jq length)
  if [ "$all_sinks" -eq 0 ]; then
    echo "No log sinks configured at all for project $GCP_PROJECT_ID."
    echo "{\"title\":\"No audit log sinks configured for project \\\`$GCP_PROJECT_ID\\\`\",\"details\":\"Project \\\`$GCP_PROJECT_ID\\\` has no Cloud Logging sinks configured. BigQuery audit events are not being exported or monitored.\",\"severity\":2,\"next_steps\":\"Create a log sink for BigQuery audit logs using: gcloud logging sinks create bq-audit-sink storage.googleapis.com/projects/_/buckets/bq-audit-logs --log-filter='resource.type=bigquery_dataset AND protoPayload.serviceName=bigquery.googleapis.com' --include-children --project=$GCP_PROJECT_ID\",\"expected\":\"At least one log sink should capture BigQuery audit events\",\"actual\":\"No log sinks configured\",\"issue_type\":\"no_audit_sinks\"}" > "$OUTPUT_FILE"
    jq . "$OUTPUT_FILE"
    exit 0
  fi

  # Check for any sink that might capture BigQuery
  broad_sinks=$(echo "$log_sinks" | jq '[.[] | select(.filter == null or .filter == "" or (.filter | test("allAudiences|allLogs|ALL", "i")))]')
  broad_count=$(echo "$broad_sinks" | jq length)
  if [ "$broad_count" -eq 0 ]; then
    echo "No sinks found that capture BigQuery audit logs."
    echo "{\"title\":\"BigQuery audit logs not captured by any log sink in project \\\`$GCP_PROJECT_ID\\\`\",\"details\":\"Project \\\`$GCP_PROJECT_ID\\\` has log sinks but none of them appear to capture BigQuery audit events. Consider adding a BigQuery-specific sink.\",\"severity\":3,\"next_steps\":\"Add a log filter for BigQuery: resource.type=bigquery_dataset AND protoPayload.serviceName=bigquery.googleapis.com to an existing sink or create a new one.\",\"expected\":\"BigQuery audit events should be captured by a log sink\",\"actual\":\"No sink captures BigQuery audit logs\",\"issue_type\":\"bq_audit_not_captured\"}" > "$OUTPUT_FILE"
    jq . "$OUTPUT_FILE"
    exit 0
  fi
fi

# Check Data Access audit log configuration
echo "Checking Data Access audit log configuration..."
# Try to get audit config via organization/policy
audit_logs_enabled=false

# Check if any sink has bigquery filter
bq_sink_details=$(echo "$bq_sinks" | jq -c '.[0] // {}')
if [ "$bq_sink_count" -gt 0 ]; then
  audit_logs_enabled=true
  echo "Found $bq_sink_count BigQuery-related log sink(s)."
fi

if [ "$audit_logs_enabled" = false ]; then
  echo "{\"title\":\"BigQuery Data Access audit logs may not be enabled in project \\\`$GCP_PROJECT_ID\\\`\",\"details\":\"Unable to confirm that Data Access audit logs are enabled for BigQuery in project \\\`$GCP_PROJECT_ID\\\`. Data Access audit logs are required for compliance and security monitoring.\",\"severity\":2,\"next_steps\":\"Enable Data Access audit logs for BigQuery via the GCP Console: IAM & Admin > Audit Logs > BigQuery > Data Access (Admin Read, Data Read, Data Write).\",\"expected\":\"BigQuery Data Access audit logs should be enabled\",\"actual\":\"Cannot confirm Data Access audit logs are enabled\",\"issue_type\":\"audit_logs_maybe_disabled\"}" > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Audit logging check completed."
jq . "$OUTPUT_FILE"