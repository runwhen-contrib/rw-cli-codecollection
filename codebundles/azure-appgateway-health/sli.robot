*** Settings ***
Documentation       Queries the health of an Azure Application Gateway, returning 1 when it's healthy and 0 when it's unhealthy.
Metadata            Author    jon-funk
Metadata            Display Name    Azure Application Gateway Health
Metadata            Supports    Azure    Application Gateway    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check AppService `${APPGATEWAY}` Health Status In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks the health status of a application gateway and its backend pools.
    [Tags]    
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=appgateway_health.sh
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
    ${APPGATEWAY}=    RW.Core.Import User Variable    APPGATEWAY
    ...    type=string
    ...    description=The Azure Application Gateway to health check.
    ...    pattern=\w*
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    Set Suite Variable    ${APPGATEWAY}    ${APPGATEWAY}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable
    ...    ${env}
    ...    {"APPGATEWAY":"${APPGATEWAY}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}"}
