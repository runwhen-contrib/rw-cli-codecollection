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
    ...    secret__AZ_USERNAME=${AZ_USERNAME}
    ...    secret__AZ_SECRET_VALUE=${AZ_SECRET_VALUE}
    ...    secret__AZ_TENANT=${AZ_TENANT}
    ...    secret__AZ_SUBSCRIPTION=${AZ_SUBSCRIPTION}
    ...    timeout_seconds=180
    ...    include_in_history=false
    IF    ${process.returncode} > 0
        RW.Core.Push Metric    0
    ELSE
        RW.Core.Push Metric    1
    END

*** Keywords ***
Suite Initialization
    ${AZ_USERNAME}=    RW.Core.Import Secret
    ...    AZ_USERNAME
    ...    type=string
    ...    description=The azure service principal client ID on the app registration.
    ...    pattern=\w*
    ${AZ_SECRET_VALUE}=    RW.Core.Import Secret
    ...    AZ_SECRET_VALUE
    ...    type=string
    ...    description=The service principal secret value on the associated credential for the app registration.
    ...    pattern=\w*
    ${AZ_TENANT}=    RW.Core.Import Secret
    ...    AZ_TENANT
    ...    type=string
    ...    description=The azure tenant ID used by the service principal to authenticate with azure.
    ...    pattern=\w*
    ${AZ_SUBSCRIPTION}=    RW.Core.Import Secret
    ...    AZ_SUBSCRIPTION
    ...    type=string
    ...    description=The azure tenant ID used by the service principal to authenticate with azure.
    ...    pattern=\w*
    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group to perform actions against.
    ...    pattern=\w*
    ${APPGATEWAY}=    RW.Core.Import User Variable    APPGATEWAY
    ...    type=string
    ...    description=The Azure Application Gateway to health check.
    ...    pattern=\w*

    Set Suite Variable    ${APPGATEWAY}    ${APPGATEWAY}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${AZ_USERNAME}    ${AZ_USERNAME}
    Set Suite Variable    ${AZ_SECRET_VALUE}    ${AZ_SECRET_VALUE}
    Set Suite Variable    ${AZ_TENANT}    ${AZ_TENANT}
    Set Suite Variable    ${AZ_SUBSCRIPTION}    ${AZ_SUBSCRIPTION}
    Set Suite Variable
    ...    ${env}
    ...    {"APPGATEWAY":"${APPGATEWAY}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}"}
