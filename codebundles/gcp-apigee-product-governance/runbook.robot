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
Discover Apigee API Products, Developers and Apps in `${APIGEE_ORG}`
    [Documentation]    Lists all API products, developers and developer apps at org scope (with consumer keys) so downstream governance tasks can evaluate entitlements without per-object looping. This is also the single task that reports an inability to read the organization at all.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:config
    ${discover_result}=    RW.CLI.Run Bash File
    ...    bash_file=discover_entitlements.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./discover_entitlements.sh
    Report Issues From File    entitlements_discovery_issues.json    ${discover_result.cmd}    Apigee entitlement discovery    entitlements_discovery_status.json
    RW.Core.Add Pre To Report    Apigee Entitlement Discovery:\n${discover_result.stdout}

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
    ...
    ...    applicable=false is NOT a failure -- it is a positive determination
    ...    that the project has no Apigee organization -- so it is reported as
    ...    context and raises nothing. See the README, "Projects without Apigee".
    [Arguments]    ${status_file}    ${reproduce_hint}    ${check_label}
    ${verdict}=    RW.CLI.Run Cli
    ...    cmd=if [ -s "${status_file}" ]; then jq -r 'if .access_ok == true then (if has("applicable") and .applicable == false then "n/a" else "ok" end) else "fail" end' "${status_file}"; else echo "missing"; fi
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
    ELSE IF    "${state}" == "n/a"
        Log    ${check_label}: no Apigee organization in this project; nothing to check.    INFO
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
    # No `|| true` here: a failed service-account activation makes every
    # subsequent API call fail, and the discovery task must be able to report
    # that rather than have it swallowed.
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}"
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
