*** Settings ***
Documentation       Investigate Azure Storage Account utilization, ownership, dependencies, and access patterns to support safe remediation of public blob access and shared key authentication.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Azure Storage Account Investigation
Metadata            Supports    Azure    Storage Account    Investigation    Security    RBAC    Dependencies    Metrics    Logs
Force Tags          Azure    Storage Account    Investigation    Security    access:read-only

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
List Storage Account RBAC Role Assignments for `${AZURE_STORAGE_ACCOUNT_NAME}`
    [Documentation]    Identify principals with RBAC access to the storage account including inherited assignments and flag over-privileged or user-based data-plane access.
    [Tags]    Azure    Storage    RBAC    Security    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=list-rbac-assignments.sh
    ...    env=${env}
    ...    secret__azure_credentials=${azure_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./list-rbac-assignments.sh

    RW.Core.Add Pre To Report    ${result.stderr}

    TRY
        ${payload}=    Evaluate    json.loads(r'''${result.stdout}''')    json
        ${issue_list}=    Set Variable    ${payload['issues']}
    EXCEPT
        Log    Failed to parse JSON for RBAC task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Query Resource Graph for Storage Account Dependencies for `${AZURE_STORAGE_ACCOUNT_NAME}`
    [Documentation]    Map Azure resources referencing the storage account via Resource Graph to quantify blast radius before disabling public access.
    [Tags]    Azure    Storage    Dependencies    ResourceGraph    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=query-dependencies.sh
    ...    env=${env}
    ...    secret__azure_credentials=${azure_credentials}
    ...    timeout_seconds=240
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./query-dependencies.sh

    RW.Core.Add Pre To Report    ${result.stderr}

    TRY
        ${payload}=    Evaluate    json.loads(r'''${result.stdout}''')    json
        ${issue_list}=    Set Variable    ${payload['issues']}
    EXCEPT
        Log    Failed to parse JSON for dependencies task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Analyze Storage Account Transaction Metrics by Authentication Type for `${AZURE_STORAGE_ACCOUNT_NAME}`
    [Documentation]    Pull Azure Monitor blob transaction metrics by authentication type and assess risk of disabling public access or shared key authentication.
    [Tags]    Azure    Storage    Metrics    Authentication    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze-transaction-metrics.sh
    ...    env=${env}
    ...    secret__azure_credentials=${azure_credentials}
    ...    timeout_seconds=240
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./analyze-transaction-metrics.sh

    RW.Core.Add Pre To Report    ${result.stderr}

    TRY
        ${payload}=    Evaluate    json.loads(r'''${result.stdout}''')    json
        ${issue_list}=    Set Variable    ${payload['issues']}
    EXCEPT
        Log    Failed to parse JSON for metrics task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

Query Storage Account Access Logs for `${AZURE_STORAGE_ACCOUNT_NAME}`
    [Documentation]    Query StorageBlobLogs for caller IPs, identities, and authentication types; short-circuits when diagnostic settings are not enabled.
    [Tags]    Azure    Storage    Logs    Access    access:read-only    data:logs-config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=query-access-logs.sh
    ...    env=${env}
    ...    secret__azure_credentials=${azure_credentials}
    ...    timeout_seconds=300
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./query-access-logs.sh

    RW.Core.Add Pre To Report    ${result.stderr}

    TRY
        ${payload}=    Evaluate    json.loads(r'''${result.stdout}''')    json
        ${issue_list}=    Set Variable    ${payload['issues']}
    EXCEPT
        Log    Failed to parse JSON for access logs task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END


*** Keywords ***
Suite Initialization
    TRY
        ${azure_credentials}=    RW.Core.Import Secret
        ...    azure_credentials
        ...    type=string
        ...    description=Azure Service Principal credentials (clientId, clientSecret, tenantId, subscriptionId)
        ...    pattern=\w*
        Set Suite Variable    ${azure_credentials}    ${azure_credentials}
    EXCEPT
        Log    azure_credentials secret not found; relying on ambient az login context    WARN
        Set Suite Variable    ${azure_credentials}    ${EMPTY}
    END

    ${AZURE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=Azure subscription ID containing the storage account
    ...    pattern=\w*
    ${AZURE_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZURE_RESOURCE_GROUP
    ...    type=string
    ...    description=Resource group containing the storage account
    ...    pattern=\w*
    ${AZURE_STORAGE_ACCOUNT_NAME}=    RW.Core.Import User Variable    AZURE_STORAGE_ACCOUNT_NAME
    ...    type=string
    ...    description=Name of the storage account to investigate
    ...    pattern=\w*
    ${LOOKBACK_DAYS}=    RW.Core.Import User Variable    LOOKBACK_DAYS
    ...    type=string
    ...    description=Days of metrics and logs to analyze
    ...    pattern=\d+
    ...    default=7
    ${ADDITIONAL_SUBSCRIPTION_IDS}=    RW.Core.Import User Variable    ADDITIONAL_SUBSCRIPTION_IDS
    ...    type=string
    ...    description=Comma-separated subscription IDs for cross-subscription Resource Graph queries
    ...    pattern=[\w,\-]*
    ...    default=${EMPTY}
    ${LOG_ANALYTICS_WORKSPACE_ID}=    RW.Core.Import User Variable    LOG_ANALYTICS_WORKSPACE_ID
    ...    type=string
    ...    description=Log Analytics workspace ID for StorageBlobLogs queries
    ...    pattern=[\w/\-]*
    ...    default=${EMPTY}

    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${AZURE_STORAGE_ACCOUNT_NAME}    ${AZURE_STORAGE_ACCOUNT_NAME}
    Set Suite Variable    ${LOOKBACK_DAYS}    ${LOOKBACK_DAYS}
    Set Suite Variable    ${ADDITIONAL_SUBSCRIPTION_IDS}    ${ADDITIONAL_SUBSCRIPTION_IDS}
    Set Suite Variable    ${LOG_ANALYTICS_WORKSPACE_ID}    ${LOG_ANALYTICS_WORKSPACE_ID}

    ${env_dict}=    Create Dictionary
    ...    AZURE_SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}
    ...    AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP}
    ...    AZURE_STORAGE_ACCOUNT_NAME=${AZURE_STORAGE_ACCOUNT_NAME}
    ...    LOOKBACK_DAYS=${LOOKBACK_DAYS}
    ...    ADDITIONAL_SUBSCRIPTION_IDS=${ADDITIONAL_SUBSCRIPTION_IDS}
    ...    LOG_ANALYTICS_WORKSPACE_ID=${LOG_ANALYTICS_WORKSPACE_ID}
    Set Suite Variable    ${env}    ${env_dict}

    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_SUBSCRIPTION_ID}
    ...    include_in_history=false
