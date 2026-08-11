#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# Checks that admin activity, data access, and policy denied audit logging modes
# are enabled and that a log sink or log export exists so the log-based audit
# tasks are meaningful. Flags projects missing audit logging as a coverage gap.
#
# Outputs: audit_log_config_issues.json  (JSON array of issue objects)
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="audit_log_config_issues.json"
issues_json='[]'

echo "Verifying Cloud Audit Log configuration for project: $GCP_PROJECT_ID"

# Audit log config (admin read / data read / data write / policy denied) is part
# of the project IAM policy under auditConfigs.
iam_policy='{}'
if ! iam_policy=$(gcloud projects get-iam-policy "$GCP_PROJECT_ID" --format=json 2>err.log); then
    err_msg=$(cat err.log)
    rm -f err.log
    echo "WARN: Could not read IAM policy: $err_msg"
    echo "{\"title\":\"Unable to read IAM policy for project \\\`$GCP_PROJECT_ID\\\`\",\"details\":\"gcloud projects get-iam-policy failed: $err_msg. The service account may lack resourcemanager.projects.getIamPolicy.\",\"severity\":1,\"next_steps\":\"Grant resourcemanager.projects.getIamPolicy to the service account.\",\"expected\":\"IAM policy is readable\",\"actual\":\"gcloud projects get-iam-policy returned an error\"}" > "$OUTPUT_FILE"
    exit 0
fi

audit_configs=$(echo "$iam_policy" | jq -r '.auditConfigs // [] | length')
echo "Audit config entries found: $audit_configs"

# Pick the audit config covering all services (service == ALL_SERVICES or empty)
audit_config='{}'
if [ "$audit_configs" -gt 0 ]; then
    audit_config=$(echo "$iam_policy" | jq -c '[.auditConfigs[] | select((.service // "") == "" or (.service == "allServices") or (.service == "ALL_SERVICES"))][0] // {}')
fi

admin_read=$(echo "$audit_config" | jq -r '[.auditLogConfigs[] | select(.logType=="ADMIN_READ")] | length')
data_read=$(echo "$audit_config" | jq -r '[.auditLogConfigs[] | select(.logType=="DATA_READ")] | length')
data_write=$(echo "$audit_config" | jq -r '[.auditLogConfigs[] | select(.logType=="DATA_WRITE")] | length')
policy_denied=$(echo "$audit_config" | jq -r '[.auditLogConfigs[] | select(.logType=="POLICY_DENIED")] | length')

echo "Admin Read: $admin_read, Data Read: $data_read, Data Write: $data_write, Policy Denied: $policy_denied"

# Check that at least one log sink / export exists so logs are queryable/exported
sinks='[]'
sinks=$(gcloud logging sinks list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")
sink_count=$(echo "$sinks" | jq length)
echo "Log sinks found: $sink_count"

# Coverage-gap: no audit config or no sinks -> the log-based tasks are not meaningful
if [ "$audit_configs" -eq 0 ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Audit logging configuration missing for project \`$GCP_PROJECT_ID\`" \
        --arg details "No auditConfigs were found for project \`$GCP_PROJECT_ID\`. Admin activity, data access, and policy denied audit logs are not enabled, so log-based audit tasks (permission denied, IAM changes) may produce no meaningful results." \
        --arg expected "Audit logging modes (ADMIN_READ, DATA_READ, DATA_WRITE, POLICY_DENIED) enabled for the project" \
        --arg actual "No auditConfigs found" \
        --arg next_steps "Enable audit logs in the GCP Console (IAM & Admin > Audit Logs) or via API: set auditConfigs with ADMIN_READ, DATA_READ, DATA_WRITE, POLICY_DENIED log types for allServices." \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": 3,
           "expected": $expected,
           "actual": $actual,
           "next_steps": $next_steps,
           "issue_type": "audit_logging_missing"
         }]')
elif [ "$data_read" -eq 0 ] || [ "$data_write" -eq 0 ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Data access audit logging not fully enabled for project \`$GCP_PROJECT_ID\`" \
        --arg details "Admin Read: $admin_read, Data Read: $data_read, Data Write: $data_write, Policy Denied: $policy_denied. Data access audit logs must be enabled for full visibility into resource access." \
        --arg expected "ADMIN_READ, DATA_READ, DATA_WRITE, and POLICY_DENIED audit log types enabled" \
        --arg actual "Data Read count=$data_read, Data Write count=$data_write" \
        --arg next_steps "Enable DATA_READ and DATA_WRITE audit log types for the service(s) in question via IAM & Admin > Audit Logs." \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": 2,
           "expected": $expected,
           "actual": $actual,
           "next_steps": $next_steps,
           "issue_type": "data_access_audit_partial"
         }]')
fi

# Coverage-gap: no sink / export means logs are not retained or exported
if [ "$sink_count" -eq 0 ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "No log sink configured for project \`$GCP_PROJECT_ID\`" \
        --arg details "No Cloud Logging sinks were found for project \`$GCP_PROJECT_ID\`. Without a sink or log export, audit logs may not be retained or exported for long-term analysis." \
        --arg expected "At least one log sink or export exists for the project" \
        --arg actual "No log sinks found" \
        --arg next_steps "Create a log sink to retain/export logs, e.g.: gcloud logging sinks create gcp-audit-sink storage.googleapis.com/projects/_/buckets/your-bucket --include-children --project=$GCP_PROJECT_ID" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": 2,
           "expected": $expected,
           "actual": $actual,
           "next_steps": $next_steps,
           "issue_type": "no_log_sink"
         }]')
fi

if [ "$audit_configs" -gt 0 ] && [ "$sink_count" -gt 0 ]; then
    echo "Audit logging and sinks are configured for project $GCP_PROJECT_ID."
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Audit log configuration verification completed. Results saved to $OUTPUT_FILE"
jq . "$OUTPUT_FILE" 2>/dev/null || true
