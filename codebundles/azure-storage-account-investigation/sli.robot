*** Settings ***
Documentation       Measures investigation completeness for an Azure Storage Account by scoring account access, RBAC enumeration, metrics availability, and diagnostic log forwarding.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Azure Storage Account Investigation SLI
Metadata            Supports    Azure    Storage Account    Investigation    SLI
Suite Setup         Suite Initialization

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform


*** Tasks ***
Check Storage Account Accessibility for `${AZURE_STORAGE_ACCOUNT_NAME}`
    [Documentation]    Verifies the storage account is readable via Azure CLI.
    [Tags]    access:read-only    data:config
    ${result}=    RW.CLI.Run Cli
    ...    cmd=az storage account show --name "${AZURE_STORAGE_ACCOUNT_NAME}" --resource-group "${AZURE_RESOURCE_GROUP}" --subscription "${AZURE_SUBSCRIPTION_ID}" -o json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${info}=    Evaluate    json.loads(r'''${result.stdout}''')    json
        ${score}=    Set Variable    ${1}
    EXCEPT
        ${score}=    Set Variable    ${0}
    END
    Set Suite Variable    ${account_score}    ${score}
    RW.Core.Push Metric    ${score}    sub_name=account_accessible

Check RBAC Enumeration for `${AZURE_STORAGE_ACCOUNT_NAME}`
    [Documentation]    Scores whether RBAC assignments can be listed for the storage account.
    [Tags]    access:read-only    data:config
    ${resource_id}=    RW.CLI.Run Cli
    ...    cmd=az storage account show --name "${AZURE_STORAGE_ACCOUNT_NAME}" --resource-group "${AZURE_RESOURCE_GROUP}" --subscription "${AZURE_SUBSCRIPTION_ID}" --query id -o tsv
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ${rbac}=    RW.CLI.Run Cli
    ...    cmd=az role assignment list --scope "${resource_id.stdout.strip()}" --include-inherited --all -o json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${assignments}=    Evaluate    json.loads(r'''${rbac.stdout}''')    json
        ${score}=    Evaluate    1 if len(@{assignments}) >= 0 and "${rbac.return_code}" == "0" else 0
    EXCEPT
        ${score}=    Set Variable    ${0}
    END
    Set Suite Variable    ${rbac_score}    ${score}
    RW.Core.Push Metric    ${score}    sub_name=rbac_enumerated

Check Metrics Availability for `${AZURE_STORAGE_ACCOUNT_NAME}`
    [Documentation]    Scores whether blob transaction metrics are queryable.
    [Tags]    access:read-only    data:metrics
    ${resource_id}=    RW.CLI.Run Cli
    ...    cmd=az storage account show --name "${AZURE_STORAGE_ACCOUNT_NAME}" --resource-group "${AZURE_RESOURCE_GROUP}" --subscription "${AZURE_SUBSCRIPTION_ID}" --query id -o tsv
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ${blob_id}=    Set Variable    ${resource_id.stdout.strip()}/blobServices/default
    ${metrics}=    RW.CLI.Run Cli
    ...    cmd=az monitor metrics list --resource "${blob_id}" --metric Transactions --aggregation Total --interval PT1H --offset 1d -o json
    ...    env=${env}
    ...    timeout_seconds=90
    ...    include_in_history=false
    TRY
        ${payload}=    Evaluate    json.loads(r'''${metrics.stdout}''')    json
        ${score}=    Evaluate    1 if 'value' in $payload else 0
    EXCEPT
        ${score}=    Set Variable    ${0}
    END
    Set Suite Variable    ${metrics_score}    ${score}
    RW.Core.Push Metric    ${score}    sub_name=metrics_available

Check Diagnostic Log Forwarding for `${AZURE_STORAGE_ACCOUNT_NAME}`
    [Documentation]    Scores whether blob diagnostic settings forward logs to Log Analytics.
    [Tags]    access:read-only    data:logs-config
    ${resource_id}=    RW.CLI.Run Cli
    ...    cmd=az storage account show --name "${AZURE_STORAGE_ACCOUNT_NAME}" --resource-group "${AZURE_RESOURCE_GROUP}" --subscription "${AZURE_SUBSCRIPTION_ID}" --query id -o tsv
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ${blob_id}=    Set Variable    ${resource_id.stdout.strip()}/blobServices/default
    ${diag}=    RW.CLI.Run Cli
    ...    cmd=az monitor diagnostic-settings list --resource "${blob_id}" -o json
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    TRY
        ${settings}=    Evaluate    json.loads(r'''${diag.stdout}''')    json
        ${score}=    Evaluate    1 if len(@{settings}) > 0 and any(s.get('workspaceId') for s in $settings) else 0
    EXCEPT
        ${score}=    Set Variable    ${0}
    END
    Set Suite Variable    ${logs_score}    ${score}
    RW.Core.Push Metric    ${score}    sub_name=logs_enabled

Generate Investigation Completeness Score for `${AZURE_STORAGE_ACCOUNT_NAME}`
    [Documentation]    Averages dimension scores into a 0-1 investigation completeness metric.
    [Tags]    access:read-only    data:config
    ${health_score}=    Evaluate    (${account_score} + ${rbac_score} + ${metrics_score} + ${logs_score}) / 4
    ${health_score}=    Convert To Number    ${health_score}    2
    RW.Core.Add to Report    Investigation completeness score: ${health_score}
    RW.Core.Push Metric    ${health_score}


*** Keywords ***
Suite Initialization
    TRY
        ${azure_credentials}=    RW.Core.Import Secret
        ...    azure_credentials
        ...    type=string
        ...    description=Azure Service Principal credentials
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

    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${AZURE_STORAGE_ACCOUNT_NAME}    ${AZURE_STORAGE_ACCOUNT_NAME}
    Set Suite Variable    ${account_score}    ${0}
    Set Suite Variable    ${rbac_score}    ${0}
    Set Suite Variable    ${metrics_score}    ${0}
    Set Suite Variable    ${logs_score}    ${0}

    ${env_dict}=    Create Dictionary
    ...    AZURE_SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}
    ...    AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP}
    ...    AZURE_STORAGE_ACCOUNT_NAME=${AZURE_STORAGE_ACCOUNT_NAME}
    Set Suite Variable    ${env}    ${env_dict}

    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_SUBSCRIPTION_ID}
    ...    include_in_history=false
