*** Settings ***
Documentation       Performs a health check on Azure Data factories
Metadata            Author    saurabh3460
Metadata            Display Name    Azure Data factories Health
Metadata            Supports    Azure    Data factories

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check for Azure Data Factories Health in resource group `${AZURE_RESOURCE_GROUP}` in Subscription `${AZURE_SUBSCRIPTION_NAME}`
    [Documentation]    Fetch health status for all Data Factories in the resource group
    [Tags]    datafactory    resourcehealth   access:read-only
    ${json_file}=    Set Variable    "datafactory_health.json"
    ${resource_health}=    RW.CLI.Run Bash File
    ...    bash_file=resource_health.sh
    ...    env=${env}
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${json_file}
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    ${availability_score}=    Evaluate    len([issue for issue in ${issue_list} if issue["properties"]["title"] != "Available"]) if len(@{issue_list}) > 0 else 0
    Set Global Variable    ${availability_score}
    RW.CLI.Run Cli
    ...    cmd=rm -f ${json_file}

Generate Health Score
    ${ado_health_score}=      Evaluate  (${availability_score} ) / 1
    ${health_score}=      Convert to Number    ${ado_health_score}  2
    RW.Core.Push Metric    ${health_score}

*** Keywords ***
Suite Initialization
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    ${AZURE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID for the resource.  
    ...    pattern=\w*
    ...    default=""
    ${AZURE_SUBSCRIPTION_NAME}=    RW.Core.Import User Variable    AZURE_SUBSCRIPTION_NAME
    ...    type=string
    ...    description=The Azure Subscription Name.  
    ...    pattern=\w*
    ...    default=""
    ${AZURE_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZURE_RESOURCE_GROUP
    ...    type=string
    ...    description=Azure resource group.
    ...    pattern=\w*
    Set Suite Variable    ${AZURE_SUBSCRIPTION_NAME}    ${AZURE_SUBSCRIPTION_NAME}
    Set Suite Variable    ${AZURE_SUBSCRIPTION_ID}    ${AZURE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZURE_RESOURCE_GROUP}    ${AZURE_RESOURCE_GROUP}
    Set Suite Variable
    ...    ${env}
    ...    {"AZURE_RESOURCE_GROUP":"${AZURE_RESOURCE_GROUP}", "AZURE_SUBSCRIPTION_ID":"${AZURE_SUBSCRIPTION_ID}", "AZURE_SUBSCRIPTION_NAME":"${AZURE_SUBSCRIPTION_NAME}"}