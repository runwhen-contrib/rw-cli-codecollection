*** Settings ***
Documentation       Governs the consumer-side entitlement layer of an Apigee X organization: API products, developer apps and their consumer keys/credentials, plus developer status and dangling references.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Apigee Product and Developer Governance
Metadata            Supports    GCP    Apigee    Products    Developers    Apps    Governance
Force Tags          GCP    Apigee    Products    Developers    Apps    Governance

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization

*** Tasks ***
Check Apigee API Product Expiry and Status in `${APIGEE_ORG}`
    [Documentation]    Flags API products that permit auto-approval (unapproved access) or that have missing/zero quota or rate limits, which weaken access control or break intended limits.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    security    access:read-only    data:config
    ${product_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_api_products.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_api_products.sh
    Report Issues From File    api_products_issues.json    ${product_result.cmd}    Apigee API product analysis    api_products_status.json
    RW.Core.Add Pre To Report    Apigee API Product Analysis:\n${product_result.stdout}

Check Apigee Developer App Credential Expiry in `${APIGEE_ORG}`
    [Documentation]    Verifies each developer-app consumer key is not expired or expiring within KEY_EXPIRY_WARNING_DAYS, flagging credentials that will silently return 401s to consumers.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:config
    ${credential_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_app_credentials.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_app_credentials.sh
    Report Issues From File    api_credentials_issues.json    ${credential_result.cmd}    Apigee consumer-key analysis    api_credentials_status.json
    RW.Core.Add Pre To Report    Apigee Consumer-Key Analysis:\n${credential_result.stdout}

Check Apigee Orphaned and Unused Products and Apps in `${APIGEE_ORG}`
    [Documentation]    Identifies API products with no developer app attached, developer apps with no consumer keys, and entitlements that see no traffic over the lookback window, for housekeeping.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:config
    ${orphaned_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_orphaned_entitlements.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_orphaned_entitlements.sh
    Report Issues From File    orphaned_entitlements_issues.json    ${orphaned_result.cmd}    Apigee orphaned/unused entitlement analysis    orphaned_entitlements_status.json
    RW.Core.Add Pre To Report    Apigee Orphaned/Unused Entitlement Analysis:\n${orphaned_result.stdout}

Check Apigee Developer Status and Dangling References in `${APIGEE_ORG}`
    [Documentation]    Flags developers that are inactive/blocked while their apps remain active, and apps whose credentials reference API products that no longer exist (dangling references).
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:state
    ${developer_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_developer_status.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_developer_status.sh
    Report Issues From File    developer_status_issues.json    ${developer_result.cmd}    Apigee developer status analysis    developer_status_status.json
    RW.Core.Add Pre To Report    Apigee Developer Status Analysis:\n${developer_result.stdout}

*** Keywords ***
Report Issues From File
    [Documentation]    Reads a check's JSON issues array and raises each entry.
    ...    If the file is missing or unparseable the check did not complete, so
    ...    that is raised as an issue in its own right. Defaulting to an empty
    ...    list would make a broken check indistinguishable from a clean one.
    ...
    ...    Also reads the check's access_ok sidecar. A check that could not read
    ...    the Apigee API writes an EMPTY issues array, so without this the
    ...    runbook would report nothing and a blind check would look clean.
    ...    There is no SLI scoring layer to catch it.
    [Arguments]    ${issues_file}    ${reproduce_hint}    ${check_label}    ${status_file}=${EMPTY}
    IF    "${status_file}" != ""
        Report Access Failure    ${status_file}    ${reproduce_hint}    ${check_label}
    END
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat "${issues_file}" 2>/dev/null || true
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues_output.stdout}''')    json
    EXCEPT    AS    ${error}
        Log    ${check_label} produced no parseable issue list: ${error}    WARN
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=${check_label} should produce a readable JSON issues array
        ...    actual=${issues_file} was missing or could not be parsed as JSON
        ...    title=${check_label} did not produce readable results
        ...    reproduce_hint=${reproduce_hint}
        ...    details=The check script did not leave a parseable ${issues_file}. Its findings are unknown -- this is not evidence that the organization is healthy. Error: ${error}
        ...    next_steps=Re-run `${reproduce_hint}` and inspect its stdout/stderr for the underlying failure.
        ${issue_list}=    Create List
    END
    FOR    ${issue}    IN    @{issue_list}
        RW.Core.Add Issue
        ...    severity=${issue['severity']}
        ...    expected=${issue['expected']}
        ...    actual=${issue['actual']}
        ...    title=${issue['title']}
        ...    reproduce_hint=${reproduce_hint}
        ...    details=${issue['details']}
        ...    next_steps=${issue['next_steps']}
    END

Report Access Failure
    [Documentation]    Raises an issue when a check's sidecar says it could not
    ...    read the Apigee API. This is what keeps "ran and found nothing" and
    ...    "could not run" distinguishable now that no SLI scores the sidecar.
    [Arguments]    ${status_file}    ${reproduce_hint}    ${check_label}
    ${verdict}=    RW.CLI.Run Cli
    ...    cmd=if [ -s "${status_file}" ]; then jq -r 'if .access_ok == true then "ok" else "fail" end' "${status_file}"; else echo "missing"; fi
    ...    env=${env}
    ${state}=    Evaluate    """${verdict.stdout}""".strip()
    IF    "${state}" == "fail"
        ${reason}=    RW.CLI.Run Cli
        ...    cmd=jq -r '.reason // "no reason recorded"' "${status_file}"
        ...    env=${env}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=${check_label} should be able to read the Apigee management API
        ...    actual=${check_label} could not read the Apigee management API: ${reason.stdout}
        ...    title=${check_label} could not run against org `${APIGEE_ORG}`
        ...    reproduce_hint=${reproduce_hint}
        ...    details=This check reported no findings because it could not read the data it needs, NOT because the organization is healthy. Reason: ${reason.stdout}
        ...    next_steps=Verify the service account holds roles/apigee.readOnlyAdmin on org `${APIGEE_ORG}` (and roles/apigee.analyticsViewer for usage data), then re-run `${reproduce_hint}`.
    ELSE IF    "${state}" == "missing"
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=${check_label} should write ${status_file} recording whether it could read the API
        ...    actual=${status_file} is missing or empty
        ...    title=${check_label} did not record whether it could run
        ...    reproduce_hint=${reproduce_hint}
        ...    details=Without the status sidecar there is no way to tell an empty result from a failed one, so this check's findings cannot be trusted either way.
        ...    next_steps=Re-run `${reproduce_hint}` and inspect its stdout/stderr.
    END

Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON key used to authenticate with gcloud and the Apigee management REST API.
    ...    pattern=\w*
    ...    example={"type": "service_account", "project_id": "my-project", ...}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP project that owns the Apigee organization.
    ...    pattern=[\w-]*
    ...    example=my-gcp-project
    ${APIGEE_ORG}=    RW.Core.Import User Variable    APIGEE_ORG
    ...    type=string
    ...    description=The Apigee organization name. If empty, it is resolved from GCP_PROJECT_ID.
    ...    default=${EMPTY}
    ...    pattern=[\w-]*
    ...    example=my-apigee-org
    ${APIPRODUCTS}=    RW.Core.Import User Variable    APIPRODUCTS
    ...    type=string
    ...    description=Comma-separated API product names to scope the analysis, or 'All'.
    ...    default=All
    ...    pattern=.*
    ${DEVELOPER_APPS}=    RW.Core.Import User Variable    DEVELOPER_APPS
    ...    type=string
    ...    description=Comma-separated developer app names to scope the analysis, or 'All'.
    ...    default=All
    ...    pattern=.*
    ${KEY_EXPIRY_WARNING_DAYS}=    RW.Core.Import User Variable    KEY_EXPIRY_WARNING_DAYS
    ...    type=string
    ...    description=Days before a developer-app consumer key expires to raise a warning (severity 3).
    ...    default=30
    ...    pattern=^\d+$
    ${USAGE_LOOKBACK_DAYS}=    RW.Core.Import User Variable    USAGE_LOOKBACK_DAYS
    ...    type=string
    ...    description=Lookback window in days for the Analytics developer_app usage cross-reference.
    ...    default=30
    ...    pattern=^\d+$
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${APIGEE_ORG}    ${APIGEE_ORG}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","APIGEE_ORG":"${APIGEE_ORG}","APIPRODUCTS":"${APIPRODUCTS}","DEVELOPER_APPS":"${DEVELOPER_APPS}","KEY_EXPIRY_WARNING_DAYS":"${KEY_EXPIRY_WARNING_DAYS}","USAGE_LOOKBACK_DAYS":"${USAGE_LOOKBACK_DAYS}"}
    # Activation is best-effort. The runner may already carry a usable identity
    # (workload identity), in which case a failed activation is cosmetic -- which
    # is why the other GCP bundles in this collection all suffix this call with
    # `|| true`. Gating the suite on the activation's exit code turned that
    # cosmetic failure into a total outage: every task reported NOT RUN.
    ${auth}=    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}

    # Determine the key file's SHAPE rather than inferring it from the activation
    # error. "Missing required argument [ACCOUNT]: An account is required when
    # using .p12 keys" does not mean the key is a p12 -- it means gcloud's
    # json.load() failed and it fell back to assuming one. That single error
    # covers an absent file, an empty file, and a file whose contents are not
    # JSON at all (a base64-encoded key stored without being decoded is the
    # usual cause), which are three different things to go fix.
    #
    # Emits a sentinel only. No byte of the key is echoed, logged or put in an
    # issue -- the shape is the diagnostic, the contents are not.
    ${keyshape}=    RW.CLI.Run CLI
    ...    cmd=f="./${gcp_credentials.key}"; if [ ! -f "$f" ]; then echo KEY_MISSING; elif [ ! -s "$f" ]; then echo KEY_EMPTY; elif [ "$(head -c 512 "$f" | tr -d '[:space:]' | cut -c1)" = "{" ]; then echo KEY_JSON; else echo KEY_NOT_JSON; fi
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    Log    gcp_credentials key file shape: ${keyshape.stdout}

    # This check is NOT tolerant, and it is the one that matters. Assert the
    # capability every downstream gcloud and curl call actually depends on -- can
    # a token be minted -- rather than the mechanism that usually supplies it.
    # With no token, those calls run as no identity at all and report an empty
    # Apigee org as a healthy one.
    ${token}=    RW.CLI.Run CLI
    ...    cmd=gcloud auth print-access-token >/dev/null 2>&1 && echo TOKEN_OK || echo TOKEN_ABSENT
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    IF    "TOKEN_ABSENT" in """${token.stdout}"""
        RW.Core.Add Issue
        ...    severity=1
        ...    expected=An access token should be obtainable, whether from the gcp_credentials key or from an ambient runner identity.
        ...    actual=No access token could be minted, so no Apigee API call in this run can be trusted.
        ...    title=Cannot authenticate to GCP with the supplied credentials
        ...    reproduce_hint=gcloud auth activate-service-account --key-file=<gcp_credentials> && gcloud auth print-access-token
        ...    details=gcp_credentials key file shape: ${keyshape.stdout}\n(KEY_JSON = well-formed, so suspect the key's contents or IAM; KEY_NOT_JSON = not JSON at all, commonly a base64-encoded key stored without decoding; KEY_EMPTY / KEY_MISSING = the secret did not reach the runner.)\n\nactivate-service-account stderr:\n${auth.stderr}\n\nprint-access-token stderr:\n${token.stderr}
        ...    next_steps=Verify the gcp_credentials secret contains a valid, non-expired service account JSON key for project ${GCP_PROJECT_ID}, stored as raw JSON rather than base64.
        Fail    Could not obtain a GCP access token; not attempting any check.
    END

    Discover Apigee Entitlements

Discover Apigee Entitlements
    [Documentation]    Enumerates API products, developers and developer apps at
    ...    org scope and writes the inventory the report draws on.
    ...
    ...    This runs in setup rather than as a task because it can raise no
    ...    finding an operator would act on that a check does not already raise.
    ...    Its real value is failing fast: when the organization cannot be read,
    ...    every check would fail on the same root cause, which as tasks is five
    ...    red entries for one problem. Here it is one error naming the cause,
    ...    and the checks are not attempted.
    ${discover_result}=    RW.CLI.Run Bash File
    ...    bash_file=discover_entitlements.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./discover_entitlements.sh
    RW.Core.Add Pre To Report    Apigee Entitlement Discovery:\n${discover_result.stdout}

    # The inventory must exist even when it is empty, so a MISSING file is an
    # error rather than being mistaken for an empty organization.
    ${inventory}=    RW.CLI.Run Cli
    ...    cmd=if [ -s entitlements_discovery_status.json ]; then jq -r 'if .access_ok != true then "fail" else "ok" end' entitlements_discovery_status.json; else echo "missing"; fi
    ...    env=${env}
    ${state}=    Evaluate    """${inventory.stdout}""".strip()

    IF    "${state}" == "fail"
        ${reason}=    RW.CLI.Run Cli
        ...    cmd=jq -r '.reason // "no reason recorded"' entitlements_discovery_status.json
        ...    env=${env}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=The Apigee organization for project `${GCP_PROJECT_ID}` should be readable
        ...    actual=The Apigee organization could not be read: ${reason.stdout}
        ...    title=Cannot read Apigee entitlements for project `${GCP_PROJECT_ID}`
        ...    reproduce_hint=${discover_result.cmd}
        ...    details=Discovery could not enumerate the organization, so no governance check can run. Every check below would fail for this same reason, so they were not attempted. This is not evidence that the entitlement layer is healthy. Reason: ${reason.stdout}
        ...    next_steps=Verify the service account holds roles/apigee.readOnlyAdmin on the organization, that gcloud auth activate-service-account succeeded, and that APIGEE_ORG (if set) names an organization in project `${GCP_PROJECT_ID}`.
        Fail    Apigee entitlements could not be read: ${reason.stdout}
    ELSE IF    "${state}" == "missing"
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Discovery should write entitlements_discovery_status.json recording whether the organization was readable
        ...    actual=entitlements_discovery_status.json is missing or empty
        ...    title=Apigee discovery did not record whether it could run
        ...    reproduce_hint=${discover_result.cmd}
        ...    details=Without the status sidecar there is no way to tell an empty organization from an unreadable one, so no check below can be trusted.
        ...    next_steps=Re-run `${discover_result.cmd}` and inspect its stdout/stderr.
        Fail    Apigee discovery produced no status file; cannot tell an empty organization from an unreadable one.
    END
