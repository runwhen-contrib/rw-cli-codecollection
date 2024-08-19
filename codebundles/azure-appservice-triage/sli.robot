*** Settings ***
Documentation       Queries the health status of an App Service, and returns 0 when it's not healthy, and 1 when it is.
Metadata            Author    jon-funk
Metadata            Display Name    Azure App Service Triage
Metadata            Supports    Azure    App Service    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check AppService `${APPSERVICE}` Health Status In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks the health status of a appservice workload.
    [Tags]    
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_health.sh
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
    ${APPSERVICE}=    RW.Core.Import User Variable    APPSERVICE
    ...    type=string
    ...    description=The Azure AppService to triage.
    ...    pattern=\w*

    Set Suite Variable    ${APPSERVICE}    ${APPSERVICE}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${AZ_USERNAME}    ${AZ_USERNAME}
    Set Suite Variable    ${AZ_SECRET_VALUE}    ${AZ_SECRET_VALUE}
    Set Suite Variable    ${AZ_TENANT}    ${AZ_TENANT}
    Set Suite Variable    ${AZ_SUBSCRIPTION}    ${AZ_SUBSCRIPTION}
    Set Suite Variable
    ...    ${env}
    ...    {"APPSERVICE":"${APPSERVICE}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}"}
