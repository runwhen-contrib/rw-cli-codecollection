#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#   ORG_ID            (optional parent org used to resolve inherited constraints)
#
# Enumerates enforced Organization Policy constraints (boolean and list
# constraints) for the project and reports violations where project
# configuration contradicts the constraints, such as public bucket access
# or disabled service usage.
#
# Outputs: org_policy_violation_issues.json  (JSON array of issue objects)
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${ORG_ID:=}"

OUTPUT_FILE="org_policy_violation_issues.json"
issues_json='[]'

echo "Analyzing org policy constraint violations for project: $GCP_PROJECT_ID"

# Build the effective (inherited + project) policy. Use --effective so we see
# what is actually in force on the project.
policies='[]'
if ! policies=$(gcloud org-policies list \
    --project="$GCP_PROJECT_ID" \
    --effective \
    --format=json 2>err.log); then
    err_msg=$(cat err.log)
    rm -f err.log
    echo "WARN: Could not list org policies: $err_msg"
    echo "{\"title\":\"Unable to enumerate org policies for project \\\`$GCP_PROJECT_ID\\\`\",\"details\":\"gcloud org-policies list failed: $err_msg. The service account may lack roles/orgpolicy.policyViewer or the Cloud Resource Manager API may be disabled.\",\"severity\":1,\"next_steps\":\"Enable the Cloud Resource Manager API and grant roles/orgpolicy.policyViewer (and resourcemanager.projects.getOrgPolicy) to the service account.\",\"expected\":\"Org policies are enumerable\",\"actual\":\"gcloud org-policies list returned an error\"}" > "$OUTPUT_FILE"
    exit 0
fi

echo "Retrieved effective org policies. Evaluating security constraints..."

# --- Boolean constraints where enforced=true is SECURE ---
evaluate_boolean() {
    local constraint="$1"
    local enforced
    enforced=$(echo "$policies" | jq -r --arg c "$constraint" '.[] | select(.constraint==$c and .booleanPolicy != null) | .booleanPolicy.enforced | tostring')
    if [ "$enforced" = "false" ]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg constraint "$constraint" \
            --arg title "Org policy constraint \`$constraint\` not enforced in project \`$GCP_PROJECT_ID\`" \
            --arg details "The boolean org policy constraint \`$constraint\` is present but NOT enforced (enforced=false) on project \`$GCP_PROJECT_ID\`. This weakens the project's security posture." \
            --arg expected "Constraint \`$constraint\` should be enforced (enforced=true)" \
            --arg actual "Constraint \`$constraint\` is not enforced" \
            --arg next_steps "Set the constraint policy to enforce it: gcloud org-policies set-policy or update the org policy for project $GCP_PROJECT_ID." \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": 3,
               "expected": $expected,
               "actual": $actual,
               "next_steps": $next_steps,
               "issue_type": "org_policy_not_enforced",
               "constraint": $constraint
             }]')
    fi
}

# --- List constraint: public bucket access prevention ---
evaluate_public_access() {
    local constraint="storage.publicAccessPrevention"
    local all_values allowed
    all_values=$(echo "$policies" | jq -r --arg c "$constraint" '.[] | select(.constraint==$c) | .listPolicy.allValues // ""')
    allowed=$(echo "$policies" | jq -r --arg c "$constraint" '.[] | select(.constraint==$c) | (.listPolicy.allowedValues // []) | join(",")')
    if [ "$all_values" = "ALLOW" ] || echo "$allowed" | grep -q "not enforced"; then
        issues_json=$(echo "$issues_json" | jq \
            --arg constraint "$constraint" \
            --arg title "Public bucket access not prevented by org policy in project \`$GCP_PROJECT_ID\`" \
            --arg details "The org policy constraint \`storage.publicAccessPrevention\` is not set to 'enforced' on project \`$GCP_PROJECT_ID\`, so public (allUsers) bucket access is not blocked. Publicly accessible buckets are a serious data-exposure risk." \
            --arg expected "storage.publicAccessPrevention should be enforced to block public bucket access" \
            --arg actual "storage.publicAccessPrevention not enforced (allValues=$all_values, allowedValues=$allowed)" \
            --arg next_steps "Enforce storage.publicAccessPrevention on the project/org and set Uniform Bucket-Level Access on buckets. Review any existing public buckets." \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": 3,
               "expected": $expected,
               "actual": $actual,
               "next_steps": $next_steps,
               "issue_type": "org_policy_violation_public_bucket",
               "constraint": $constraint
             }]')
    fi
}

# --- Evaluate a set of well-known security boolean constraints ---
for c in \
    "compute.requireOsLogin" \
    "compute.disableSerialPortAccess" \
    "iam.disableServiceAccountKeyCreation" \
    "sql.restrictPublicIp" \
    "compute.skipDefaultNetworkCreation" \
    "compute.restrictLoadBalancerCreationForTypes"; do
    # Only evaluate constraints that are actually present in the effective policy
    if echo "$policies" | jq -e --arg c "$c" 'any(.[]; .constraint==$c and .booleanPolicy != null)' >/dev/null 2>&1; then
        evaluate_boolean "$c"
    fi
done

# Evaluate public bucket access prevention if the constraint is present
if echo "$policies" | jq -e --arg c "storage.publicAccessPrevention" 'any(.[]; .constraint==$c)' >/dev/null 2>&1; then
    evaluate_public_access
fi

count=$(echo "$issues_json" | jq length)
echo "Org policy violations found: $count"

echo "$issues_json" > "$OUTPUT_FILE"
echo "Org policy violation analysis completed. Results saved to $OUTPUT_FILE"
jq . "$OUTPUT_FILE" 2>/dev/null || true
