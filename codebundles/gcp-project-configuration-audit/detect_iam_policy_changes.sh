#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#   LOOKBACK_WINDOW
#
# Inspects Cloud Audit Logs for SetIamPolicy (google.iam.admin.v1.SetIamPolicy,
# IAM activity) events and reports who granted or revoked roles and on which
# resources, highlighting privileged-role changes (e.g. owner) for review.
#
# Outputs: iam_policy_changes_issues.json  (JSON array of issue objects)
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${LOOKBACK_WINDOW:=P7D}"

OUTPUT_FILE="iam_policy_changes_issues.json"
issues_json='[]'

echo "Detecting IAM policy changes in project: $GCP_PROJECT_ID (lookback: $LOOKBACK_WINDOW)"

log_filter='logName:"cloudaudit.googleapis.com/activity" AND protoPayload.methodName:SetIamPolicy'

logs='[]'
if ! logs=$(gcloud logging read "$log_filter" \
    --project="$GCP_PROJECT_ID" \
    --freshness="$LOOKBACK_WINDOW" \
    --format=json \
    --limit=500 2>err.log); then
    err_msg=$(cat err.log)
    rm -f err.log
    echo "WARN: Could not query Cloud Logging: $err_msg"
    echo "{\"title\":\"Unable to read IAM activity logs for project \\\`$GCP_PROJECT_ID\\\`\",\"details\":\"gcloud logging read failed: $err_msg. Audit logs may be disabled or the service account may lack the required logging permissions.\",\"severity\":1,\"next_steps\":\"Verify audit logging is enabled and grant roles/logging.viewer to the service account.\",\"expected\":\"IAM activity logs are queryable\",\"actual\":\"gcloud logging read returned an error\"}" > "$OUTPUT_FILE"
    exit 0
fi

total_changes=$(echo "$logs" | jq length)

echo "Total SetIamPolicy events found: $total_changes"

if [ "$total_changes" -eq 0 ]; then
    echo "No IAM policy changes detected in the lookback window."
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 0
fi

# Collect a human-readable summary of changes: principal -> role on resource
change_summary=$(echo "$logs" | jq -r '
    .[] | 
    { principal: (.protoPayload.authenticationInfo.principalEmail // "unknown"),
      resource: (.protoPayload.resourceName // (.protoPayload.serviceData."iam.policyBinding.delta" // "unknown")),
      method: .protoPayload.methodName,
      time: .timestamp } |
    "\(.time) \(.principal) via \(.method) on \(.resource)"' | head -20)

# Detect privileged-role changes (owner/admin/editor etc.) mentioned in the delta
privileged_changes=$(echo "$logs" | jq -r '[.[] | select((.protoPayload.request.policy.bindings // []) | any(.role | test("owner|admin|editor"; "i")))] | length')

echo "SetIamPolicy changes mentioning privileged roles (owner/admin/editor): $privileged_changes"

# If any privileged-role changes are present, raise a severity-3 issue for review
if [ "$privileged_changes" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Privileged IAM policy change detected in project \`$GCP_PROJECT_ID\`" \
        --arg details "Detected $privileged_changes SetIamPolicy event(s) granting or altering privileged roles (owner/admin/editor) in the last $LOOKBACK_WINDOW. Review the principals and resources changed. Recent changes:\n$change_summary" \
        --arg expected "No privileged IAM role changes in the lookback window" \
        --arg actual "$privileged_changes privileged role change event(s) found among $total_changes total SetIamPolicy events" \
        --arg next_steps "Review each privileged IAM change, confirm it was authorized, and remediate any unauthorized grants. Use gcloud projects get-iam-policy to inspect current bindings." \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": 3,
           "expected": $expected,
           "actual": $actual,
           "next_steps": $next_steps,
           "issue_type": "privileged_iam_change"
         }]')
fi

# Always report non-privileged changes as informational for review
issues_json=$(echo "$issues_json" | jq \
    --arg title "IAM policy changes detected in project \`$GCP_PROJECT_ID\`" \
    --arg details "$total_changes SetIamPolicy event(s) detected in the last $LOOKBACK_WINDOW. Review who changed IAM bindings and why. Recent changes:\n$change_summary" \
    --arg expected "No unexpected IAM policy changes in the lookback window" \
    --arg actual "$total_changes IAM policy change(s) found" \
    --arg next_steps "Review the IAM change history for unauthorized or accidental role modifications and correct any unintended bindings." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": 2,
       "expected": $expected,
       "actual": $actual,
       "next_steps": $next_steps,
       "issue_type": "iam_policy_change"
     }]')

echo "$issues_json" > "$OUTPUT_FILE"
echo "IAM policy change detection completed. Results saved to $OUTPUT_FILE"
jq . "$OUTPUT_FILE" 2>/dev/null || true
