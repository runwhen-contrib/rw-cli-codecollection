#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#   LOOKBACK_WINDOW            (ISO-8601 duration, e.g. P7D, PT6H, P30D)
#   PERMISSION_DENIED_THRESHOLD (minimum distinct events before sev-3 issue)
#
# Queries Cloud Logging admin activity + policy-denied audit logs for
# PERMISSION_DENIED events in the project over the lookback window and flags
# unusually high volumes or repeated denied actions that indicate
# misconfiguration, over-permissioning, or API/secret misuse.
#
# Outputs: permission_denied_issues.json  (JSON array of issue objects)
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${LOOKBACK_WINDOW:=P7D}"
: "${PERMISSION_DENIED_THRESHOLD:=10}"

OUTPUT_FILE="permission_denied_issues.json"
issues_json='[]'

echo "Analyzing PERMISSION_DENIED events in project: $GCP_PROJECT_ID (lookback: $LOOKBACK_WINDOW)"

log_filter='logName:"cloudaudit.googleapis.com/activity" OR logName:"cloudaudit.googleapis.com/policy" AND protoPayload.status.code=7'

logs='[]'
if ! logs=$(gcloud logging read "$log_filter" \
    --project="$GCP_PROJECT_ID" \
    --freshness="$LOOKBACK_WINDOW" \
    --format=json \
    --limit=1000 2>err.log); then
    err_msg=$(cat err.log)
    rm -f err.log
    echo "WARN: Could not query Cloud Logging: $err_msg"
    echo "{\"title\":\"Unable to read audit logs for project \\\`$GCP_PROJECT_ID\\\`\",\"details\":\"gcloud logging read failed: $err_msg. Audit logs may be disabled or the service account may lack logging.viewer / logging.logEntries.list.\",\"severity\":1,\"next_steps\":\"Verify audit logging is enabled and grant roles/logging.viewer to the service account. See the Verify Cloud Audit Log Configuration task.\",\"expected\":\"Audit logs are queryable\",\"actual\":\"gcloud logging read returned an error\"}" > "$OUTPUT_FILE"
    exit 0
fi

total_count=$(echo "$logs" | jq length)

# Count distinct principals (authenticationInfo.principalEmail) that got denied
denied_principals=$(echo "$logs" | jq -r '[.[] | select(.protoPayload.authenticationInfo.principalEmail != null) | .protoPayload.authenticationInfo.principalEmail] | unique | length')

# Count distinct denied methods
denied_methods=$(echo "$logs" | jq -r '[.[] | .protoPayload.methodName] | unique | length')

echo "Total PERMISSION_DENIED entries: $total_count"
echo "Distinct principals denied: $denied_principals"
echo "Distinct denied methods: $denied_methods"

if [ "$total_count" -eq 0 ]; then
    echo "No PERMISSION_DENIED events found in the window. Project appears healthy."
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 0
fi

# Build a list of notable denied methods and principals for the details field
top_methods=$(echo "$logs" | jq -r 'group_by(.protoPayload.methodName) | map({method: .[0].protoPayload.methodName, count: length}) | sort_by(-.count) | .[0:8] | map("\(.count)x \(.method)") | join(", ")')
top_principals=$(echo "$logs" | jq -r '[.[] | select(.protoPayload.authenticationInfo.principalEmail != null) | .protoPayload.authenticationInfo.principalEmail] | group_by(.) | map(.[0]) | .[0:8] | map(.protoPayload.authenticationInfo.principalEmail) | join(", ")')

# Raise a severity-2 informational issue for any denied activity at all
issues_json=$(echo "$issues_json" | jq \
    --arg title "PERMISSION_DENIED activity detected in project \`$GCP_PROJECT_ID\`" \
    --arg details "Found $total_count PERMISSION_DENIED events in the last $LOOKBACK_WINDOW across $denied_principals distinct principals and $denied_methods distinct methods. Denied methods: $top_methods. Principals: $top_principals." \
    --arg expected "No unexpected PERMISSION_DENIED events in the lookback window" \
    --arg actual "$total_count PERMISSION_DENIED events found" \
    --arg next_steps "Review the denied actions. Many denials can signal over-permissioning, secret rotation failures, or disabled services. Correlate with Cloud Logging for the specific resources being denied." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": 2,
       "expected": $expected,
       "actual": $actual,
       "next_steps": $next_steps,
       "issue_type": "permission_denied_activity"
     }]')

# If the volume is unusually high (>= threshold) raise a severity-3 issue
if [ "$total_count" -ge "$PERMISSION_DENIED_THRESHOLD" ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "High volume of PERMISSION_DENIED events in project \`$GCP_PROJECT_ID\`" \
        --arg details "Detected $total_count PERMISSION_DENIED events which is at or above the configured threshold of $PERMISSION_DENIED_THRESHOLD over the last $LOOKBACK_WINDOW. This may indicate a persistent misconfiguration, over-permissioning, or an application hitting denied APIs." \
        --arg expected "Fewer than $PERMISSION_DENIED_THRESHOLD PERMISSION_DENIED events in the lookback window" \
        --arg actual "$total_count events detected (threshold: $PERMISSION_DENIED_THRESHOLD)" \
        --arg next_steps "Investigate the repeated denied actions, check the affected service accounts and APIs, and correct IAM bindings or service configuration. Top denied methods: $top_methods." \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": 3,
           "expected": $expected,
           "actual": $actual,
           "next_steps": $next_steps,
           "issue_type": "permission_denied_high_volume"
         }]')
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "PERMISSION_DENIED analysis completed. Results saved to $OUTPUT_FILE"
jq . "$OUTPUT_FILE" 2>/dev/null || true
