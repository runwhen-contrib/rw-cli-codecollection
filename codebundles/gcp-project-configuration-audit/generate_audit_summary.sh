#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# Aggregates findings from the permission-denied, IAM-change, org-policy, and
# audit-log tasks into a single consolidated risk summary for the project.
#
# Outputs: audit_summary.json  (JSON object describing the risk snapshot)
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="audit_summary.json"

echo "Generating consolidated audit summary for project: $GCP_PROJECT_ID"

declare -A files=(
    [permission_denied]=permission_denied_issues.json
    [iam_policy_changes]=iam_policy_changes_issues.json
    [org_policy]=org_policy_violation_issues.json
    [audit_log]=audit_log_config_issues.json
)

total=0
declare -A counts

for key in "${!files[@]}"; do
    f="${files[$key]}"
    if [ -f "$f" ]; then
        c=$(jq 'length' "$f" 2>/dev/null || echo 0)
        counts[$key]=$c
        total=$((total + c))
    else
        counts[$key]=0
    fi
done

echo "Aggregated issue counts:"
echo "  permission_denied: ${counts[permission_denied]:-0}"
echo "  iam_policy_changes: ${counts[iam_policy_changes]:-0}"
echo "  org_policy: ${counts[org_policy]:-0}"
echo "  audit_log: ${counts[audit_log]:-0}"
echo "  TOTAL: $total"

# Build the summary JSON report object
jq -n \
    --arg project "$GCP_PROJECT_ID" \
    --argjson permission_denied "${counts[permission_denied]:-0}" \
    --argjson iam_policy_changes "${counts[iam_policy_changes]:-0}" \
    --argjson org_policy "${counts[org_policy]:-0}" \
    --argjson audit_log "${counts[audit_log]:-0}" \
    --argjson total "$total" \
    --arg summary "Audit of project $GCP_PROJECT_ID found $total total risk signal(s): ${counts[permission_denied]:-0} permission-denied, ${counts[iam_policy_changes]:-0} IAM policy change, ${counts[org_policy]:-0} org-policy, ${counts[audit_log]:-0} audit-logging." \
    '{
       "project": $project,
       "counts": {
         "permission_denied": $permission_denied,
         "iam_policy_changes": $iam_policy_changes,
         "org_policy": $org_policy,
         "audit_log": $audit_log
       },
       "total_issues": $total,
       "summary": $summary
     }' > "$OUTPUT_FILE"

jq . "$OUTPUT_FILE"
echo "Audit summary written to $OUTPUT_FILE"
