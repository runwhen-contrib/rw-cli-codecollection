#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee API Product Quota and Rate Limits
#
# Reviews every API product in the Apigee organization and raises ONE finding
# PER FAILURE MODE, each listing every affected product:
#
#   1. No quota configured at all
#   2. Quota at or above QUOTA_ABUSE_THRESHOLD
#   3. approvalType 'auto', which weakens access control
#
# These are three modes with three different remedies, so they are three issues.
# Titles carry the failure mode and the org, never a product name or a quota
# value: products come and go and quotas change, so a per-product title opens
# and closes issues on every run. The names live in details/actual.
#
# REQUIRED ENV VARS:
#   APIGEE_ORG                    - Apigee organization name
#   GCP_PROJECT_ID                - GCP project ID hosting the Apigee runtime
#
# OPTIONAL ENV VARS:
#   QUOTA_ABUSE_THRESHOLD         - Quota at/above which a product is flagged
#                                   (default 1000000)
#
# OUTPUTS:
#   quota_limits_issues.json - JSON array of issue objects
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${QUOTA_ABUSE_THRESHOLD:=1000000}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/apigee_common.sh"

OUTPUT_FILE="quota_limits_issues.json"
issues_json='[]'
no_quota=""
excessive=""
auto_approval=""

APIGEE_ORG="${APIGEE_ORG#organizations/}"

echo "Checking API product quota/rate limits for org: ${APIGEE_ORG} (abuse threshold: ${QUOTA_ABUSE_THRESHOLD})"

if ! apigee_have_token; then
    # Failure to determine, NOT a determination of absence. Suite Initialization
    # already gates on a token being mintable, so reaching here means something
    # changed mid-run -- which must be reported rather than read as a clean org.
    jq -n \
        --arg title "Cannot read Apigee API products in org \`${APIGEE_ORG}\`" \
        --arg details "Unable to obtain a GCP access token for the Apigee Admin API in project ${GCP_PROJECT_ID}. No API product was evaluated, so this run determined nothing about quotas." \
        --arg severity "3" \
        --arg expected "Apigee API access should be authenticated." \
        --arg actual "Could not obtain an access token, so no API product was evaluated." \
        --arg next_steps "Verify the service account is authenticated and has roles/apigee.readOnlyAdmin." \
        '[{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}]' \
        > "${OUTPUT_FILE}"
    exit 0
fi

# GET organizations/{org}/apiproducts is DOCUMENTED and returns
# GoogleCloudApigeeV1ListApiProductsResponse: {"apiProduct":[...]} -- note the
# SINGULAR field name.
products="$(apigee_obj_list "organizations/${APIGEE_ORG}/apiproducts" "apiProduct")"
product_count="$(echo "${products}" | jq 'length' 2>/dev/null || echo 0)"

if [ "${product_count}" -eq 0 ]; then
    # A positive determination of absence: the org genuinely publishes no API
    # products. Not a finding.
    echo "Org '${APIGEE_ORG}' has no API products; nothing to evaluate."
    echo "[]" > "${OUTPUT_FILE}"
    exit 0
fi

while IFS= read -r prod_ref; do
    [ -z "${prod_ref}" ] && continue
    prod_name="$(echo "${prod_ref}" | jq -r '.name // empty')"
    [ -z "${prod_name}" ] && continue

    quota="$(echo "${prod_ref}" | jq -r '.quota // empty')"
    quota_interval="$(echo "${prod_ref}" | jq -r '.quotaInterval // empty')"
    quota_time_unit="$(echo "${prod_ref}" | jq -r '.quotaTimeUnit // empty')"
    approval_type="$(echo "${prod_ref}" | jq -r '.approvalType // empty')"

    echo "  API product '${prod_name}': quota=${quota}/${quota_interval} ${quota_time_unit}, approval=${approval_type}"

    if [ -z "${quota}" ]; then
        no_quota="${no_quota}  - ${prod_name}: no quota, quotaInterval or quotaTimeUnit set
"
    elif [ "${quota}" -ge "${QUOTA_ABUSE_THRESHOLD}" ] 2>/dev/null; then
        excessive="${excessive}  - ${prod_name}: quota ${quota} per ${quota_interval} ${quota_time_unit}
"
    fi

    if [ "${approval_type}" = "auto" ]; then
        auto_approval="${auto_approval}  - ${prod_name}: approvalType is 'auto'
"
    fi
done < <(echo "${products}" | jq -c '.[]')

if [ -n "${no_quota}" ]; then
    issue=$(jq -n \
        --arg title "Apigee API products have no quota configured in org \`${APIGEE_ORG}\`" \
        --arg details "The following API product(s) in org ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) define no quota:
${no_quota}
Consumers of these products can make unbounded requests, which can overrun upstream backends or allow abusive traffic." \
        --arg severity "3" \
        --arg expected "Every API product should define a quota and rate limit." \
        --arg actual "$(count_lines "${no_quota}") product(s) with no quota: $(join_names "${no_quota}")." \
        --arg next_steps "Configure quota, quotaInterval and quotaTimeUnit on each listed API product to bound its request rate." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

if [ -n "${excessive}" ]; then
    issue=$(jq -n \
        --arg title "Apigee API products have an excessive quota in org \`${APIGEE_ORG}\`" \
        --arg details "The following API product(s) in org ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) have a quota at or above the abuse threshold of ${QUOTA_ABUSE_THRESHOLD}:
${excessive}
A limit this high may permit abusive or runaway traffic to reach the backend." \
        --arg severity "2" \
        --arg expected "API product quotas should stay below the abuse threshold of ${QUOTA_ABUSE_THRESHOLD}." \
        --arg actual "$(count_lines "${excessive}") product(s) at or above the threshold: $(join_names "${excessive}")." \
        --arg next_steps "Review whether each listed product genuinely needs a limit this high, and lower it to a value that matches expected consumer demand." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

if [ -n "${auto_approval}" ]; then
    issue=$(jq -n \
        --arg title "Apigee API products auto-approve access requests in org \`${APIGEE_ORG}\`" \
        --arg details "The following API product(s) in org ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) use approvalType 'auto', so developer apps are approved without review:
${auto_approval}
Any developer who registers an app immediately gains access to the APIs these products expose." \
        --arg severity "2" \
        --arg expected "API products should require manual review of access requests." \
        --arg actual "$(count_lines "${auto_approval}") product(s) using auto-approval: $(join_names "${auto_approval}")." \
        --arg next_steps "Set each listed product's approval type to 'manual' so access requests go through a review process, unless the product is deliberately public." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

echo "${issues_json}" > "${OUTPUT_FILE}"
echo "Quota/rate-limit check complete. Found $(jq length "${OUTPUT_FILE}") issue(s)."
