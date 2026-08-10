#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# check_patch_status.sh
#
# Inspects OS patch / vulnerability compliance for each target VM using the
# GCP OS Config API (vulnerability reports and OS policy compliance).
# Flags VMs with affected (missing) security patches.
#
# Required env: GCP_PROJECT_ID, VM_NAME (or "All")
# Writes      : patch_issues.json (JSON array of issue objects)
#
# Note: best effort - if OS Config returns no data (e.g. no OS policy
# assignments or no vulnerability report for the instance) no issue is raised.
# Requires roles/osconfig.viewer on the service account.
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./gcp_vm_common.sh
. "$SCRIPT_DIR/gcp_vm_common.sh"

ISSUES_FILE="patch_issues.json"
rm -f "$ISSUES_FILE"

# A failed API call or an unresolvable target records an issue (score 0) rather
# than returning an empty list, which the scorer would read as "nothing wrong".
if ! VM_LIST=$(resolve_target_vms "OS patch status"); then
    finalize_issues
    echo "Patch status check could not run for VM_NAME='${VM_NAME}' in project ${GCP_PROJECT_ID}; recorded a verification issue." >&2
    exit 0
fi
count=$(printf '%s' "$VM_LIST" | jq length)

if [ "$count" -eq 0 ]; then
    finalize_issues
    echo "No standalone VMs in project ${GCP_PROJECT_ID} (VM_NAME='All'); nothing to check."
    exit 0
fi

TOKEN=$(gcp_access_token)
if [ -z "$TOKEN" ]; then
    add_issue \
        "Unable to authenticate to the OS Config API for project \`${GCP_PROJECT_ID}\`" \
        "Could not obtain an access token via 'gcloud auth print-access-token'. Patch status could not be evaluated for the target VMs." \
        3 \
        "Verify the gcloud credentials are valid and that the service account has roles/osconfig.viewer, then re-run the check." \
        "The OS Config API should be reachable with valid credentials." \
        "OS Config API authentication failed (no access token)." \
        "{\"issue_type\":\"patch_auth_failed\"}"
    finalize_issues
    echo "Patch check could not authenticate to OS Config API."
    exit 0
fi

echo "Checking OS patch status for ${count} VM(s) in project ${GCP_PROJECT_ID}."

printf '%s' "$VM_LIST" | jq -c '.[]' | while read -r vm; do
    name=$(printf '%s' "$vm" | jq -r '.name')
    zone=$(printf '%s' "$vm" | jq -r '.zone')

    # 1) Vulnerability report: CVEs with state AFFECTED indicate missing patches.
    vuln_report=""
    if [ -n "$zone" ] && [ "$zone" != "null" ]; then
        vuln_report=$(curl -s -f -H "Authorization: Bearer ${TOKEN}" \
            "https://osconfig.googleapis.com/v1/projects/${GCP_PROJECT_ID}/locations/${zone}/instances/${name}/vulnerabilityReport" 2>/dev/null || echo "")
    fi

    affected=$(printf '%s' "$vuln_report" | jq '[.vulnerabilities[]? | select(.vulnerability.state == "AFFECTED")] | length' 2>/dev/null || echo "0")
    severity=$(printf '%s' "$vuln_report" | jq '[.vulnerabilities[]? | select(.vulnerability.severity == "CRITICAL" or .vulnerability.severity == "HIGH")] | length' 2>/dev/null || echo "0")

    if [ -n "$vuln_report" ] && [ "$affected" -gt 0 ]; then
        add_issue \
            "Compute VM \`${name}\` has ${affected} affected security vulnerability(ies)" \
            "VM \`${name}\` in project \`${GCP_PROJECT_ID}\` (zone \`${zone}\`) has ${affected} affected vulnerability(ies) reported by OS Config, ${severity} of them critical/high. These represent missing or pending security patches." \
            2 \
            "Apply the missing OS patches: 'gcloud compute os-config patch-deployments' or run a patch job against VM \`${name}\` (gcloud compute instances os-inventory ... / OS patch). Review the vulnerability report for the affected CVEs at https://console.cloud.google.com/compute/instances." \
            "VM \`${name}\` should have no affected (unpatched) security vulnerabilities." \
            "VM \`${name}\` has ${affected} affected vulnerabilities (${severity} critical/high)." \
            "{\"vm\":\"${name}\",\"zone\":\"${zone}\",\"affected\":${affected},\"critical_high\":${severity},\"issue_type\":\"missing_patches\"}"
    else
        echo "  OK ${name}: no affected vulnerabilities reported."
    fi

    # 2) OS policy compliance: VIOLATED state means an applied OS policy is out of compliance.
    compliance=""
    if [ -n "$zone" ] && [ "$zone" != "null" ]; then
        compliance=$(curl -s -f -H "Authorization: Bearer ${TOKEN}" \
            "https://osconfig.googleapis.com/v1/projects/${GCP_PROJECT_ID}/locations/${zone}/instanceOSPoliciesCompliance/${name}" 2>/dev/null || echo "")
    fi

    policy_state=$(printf '%s' "$compliance" | jq -r '.state // "NA"' 2>/dev/null || echo "NA")
    if [ -n "$compliance" ] && [ "$policy_state" = "VIOLATED" ]; then
        add_issue \
            "Compute VM \`${name}\` is out of OS policy compliance" \
            "VM \`${name}\` in project \`${GCP_PROJECT_ID}\` (zone \`${zone}\`) violates one or more operating system policies applied via OS Config (state: VIOLATED)." \
            3 \
            "Inspect the OS policy assignment details for VM \`${name}\` and remediate the violating configurations at https://console.cloud.google.com/compute/os-policies." \
            "VM \`${name}\` should satisfy all applied OS policies." \
            "VM \`${name}\` OS policy compliance state is VIOLATED." \
            "{\"vm\":\"${name}\",\"zone\":\"${zone}\",\"policy_state\":\"${policy_state}\",\"issue_type\":\"os_policy_violation\"}"
    fi
done

finalize_issues
echo "Patch status check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
exit 0
