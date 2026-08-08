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
    [Documentation]    Lists all API products, developers and developer apps at org scope (with consumer keys) so downstream governance tasks can evaluate entitlements without per-object looping.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:config
    ${discover_result}=    RW.CLI.Run Bash File
    ...    bash_file=discover_entitlements.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./discover_entitlements.sh
    ${discover_issues}=    RW.CLI.Run Cli
    ...    cmd=cat entitlements_discovery_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${discover_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse discovery JSON, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${discover_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
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
    ${product_issues}=    RW.CLI.Run Cli
    ...    cmd=cat api_products_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${product_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse API product JSON, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${product_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
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
    ${credential_issues}=    RW.CLI.Run Cli
    ...    cmd=cat api_credentials_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${credential_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse consumer-key JSON, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${credential_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
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
    ${orphaned_issues}=    RW.CLI.Run Cli
    ...    cmd=cat orphaned_entitlements_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${orphaned_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse orphaned-entitlement JSON, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${orphaned_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
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
    ${developer_issues}=    RW.CLI.Run Cli
    ...    cmd=cat developer_status_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${developer_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse developer-status JSON, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${developer_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Apigee Developer Status Analysis:\n${developer_result.stdout}

*** Keywords ***
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
    ...    description=The Apigee organization name (organizations/{org}). If empty, discovered from GCP_PROJECT_ID.
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
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
