*** Settings ***
Documentation       Measures Azure Cosmos DB configuration health as a 0-1 score from Resource Health, API settings, backup, networking, private endpoints, diagnostics, and recent activity stability.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Azure Cosmos DB Configuration Health
Metadata            Supports    Azure    Cosmos DB    Configuration    Health
Force Tags          Azure    Cosmos DB    Configuration    Health

Library    String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Score Cosmos DB Configuration Health for Account `${COSMOSDB_ACCOUNT_NAME}`
    [Documentation]    Computes binary sub-scores per configuration dimension and publishes the aggregate 0-1 health metric for alerting.
    [Tags]    Azure    CosmosDB    SLI    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=cosmosdb-sli-dimensions.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./cosmosdb-sli-dimensions.sh
    TRY
        ${payload}=    Evaluate    json.loads(r'''${result.stdout}''')    json
    EXCEPT
        Log    Failed to parse SLI JSON, emitting zero score.    WARN
        ${payload}=    Create Dictionary    dimensions=${EMPTY}    aggregate=0
    END
    TRY
        ${dims}=    Get From Dictionary    ${payload}    dimensions
        ${rh}=    Get From Dictionary    ${dims}    resource_health
        ${api}=    Get From Dictionary    ${dims}    api_consistency
        ${bu}=    Get From Dictionary    ${dims}    backup
        ${net}=    Get From Dictionary    ${dims}    network
        ${pe}=    Get From Dictionary    ${dims}    private_endpoints
        ${diag}=    Get From Dictionary    ${dims}    diagnostics
        ${act}=    Get From Dictionary    ${dims}    activity
    EXCEPT
        Log    SLI dimensions missing, defaulting to zeros.    WARN
        ${rh}=    Set Variable    0
        ${api}=    Set Variable    0
        ${bu}=    Set Variable    0
        ${net}=    Set Variable    0
        ${pe}=    Set Variable    0
        ${diag}=    Set Variable    0
        ${act}=    Set Variable    0
    END
    RW.Core.Push Metric    ${rh}    sub_name=resource_health
    RW.Core.Push Metric    ${api}    sub_name=api_consistency
    RW.Core.Push Metric    ${bu}    sub_name=backup
    RW.Core.Push Metric    ${net}    sub_name=network
    RW.Core.Push Metric    ${pe}    sub_name=private_endpoints
    RW.Core.Push Metric    ${diag}    sub_name=diagnostics
    RW.Core.Push Metric    ${act}    sub_name=activity
    TRY
        ${health_score}=    Get From Dictionary    ${payload}    aggregate
    EXCEPT
        ${health_score}=    Set Variable    0
    END
    ${health_score}=    Convert To Number    ${health_score}    4
    RW.Core.Add to Report    Cosmos DB configuration health score: ${health_score}
    RW.Core.Push Metric    ${health_score}


*** Keywords ***
Suite Initialization
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=JSON or env-style secret with Azure service principal fields used by Azure CLI login patterns in this workspace.
    ...    pattern=\w*
    ${AZ_SUBSCRIPTION}=    RW.Core.Import User Variable    AZ_SUBSCRIPTION
    ...    type=string
    ...    description=Azure subscription ID (UUID) containing the Cosmos DB account.
    ...    pattern=[a-fA-F0-9-]{36}
    ${AZURE_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZURE_RESOURCE_GROUP
    ...    type=string
    ...    description=Resource group containing the Cosmos DB account(s).
    ...    pattern=\w*
    ${COSMOSDB_ACCOUNT_NAME}=    RW.Core.Import User Variable    COSMOSDB_ACCOUNT_NAME
    ...    type=string
    ...    description=Cosmos DB account name, or All to include every account in the resource group.
    ...    default=All
    ...    pattern=\w*
    ${ACTIVITY_LOG_LOOKBACK_HOURS}=    RW.Core.Import User Variable    ACTIVITY_LOG_LOOKBACK_HOURS
    ...    type=string
    ...    description=Hours of activity log history used for the activity stability dimension.
    ...    default=168
    ...    pattern=^\d+$
    Set Suite Variable    ${AZ_SUBSCRIPTION}    ${AZ_SUBSCRIPTION}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable    ${COSMOSDB_ACCOUNT_NAME}    ${COSMOSDB_ACCOUNT_NAME}
    Set Suite Variable    ${ACTIVITY_LOG_LOOKBACK_HOURS}    ${ACTIVITY_LOG_LOOKBACK_HOURS}
    Set Suite Variable
    ...    ${env}
    ...    {"AZ_SUBSCRIPTION":"${AZ_SUBSCRIPTION}", "AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "COSMOSDB_ACCOUNT_NAME":"${COSMOSDB_ACCOUNT_NAME}", "ACTIVITY_LOG_LOOKBACK_HOURS":"${ACTIVITY_LOG_LOOKBACK_HOURS}"}
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZ_SUBSCRIPTION}
    ...    include_in_history=false
