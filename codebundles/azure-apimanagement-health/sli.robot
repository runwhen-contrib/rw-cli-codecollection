*** Settings ***
Documentation       Checks API Management Service key metrics and returns a 1 when healthy, or 0 when not healthy.
Metadata            Author    jon-funk
Metadata            Display Name    Azure API Management Service Health
Metadata            Supports    Azure      API Management Service    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization
*** Tasks ***
Check API Management Service `${API}` Key Metrics In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks key metrics of API Management Service for issues.
    [Tags]    API Management Service       Azure    Metrics    Health
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=api_metrics.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    IF    ${process.returncode} > 0
        RW.Core.Push Metric    0
    ELSE
        RW.Core.Push Metric    1
    END

*** Keywords ***
Suite Initialization
    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group to perform actions against.
    ...    pattern=\w*
    ${API}=    RW.Core.Import User Variable    API
    ...    type=string
    ...    description=The Azure Virtual Machine API Management Service to triage.
    ...    pattern=\w*
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    Set Suite Variable    ${API}    ${API}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable
    ...    ${env}
    ...    {"API":"${API}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}"}