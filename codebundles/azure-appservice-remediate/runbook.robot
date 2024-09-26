*** Settings ***
Documentation       Provides tasks for scaling, restarting and remediating App Service workloads.
Metadata            Author    jon-funk
Metadata            Display Name    Azure App Service Remediation
Metadata            Supports    Azure    App Service    Remediation    Scale    Restart

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Restart App Service `${APPSERVICE}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Restarts the App Service.
    [Tags]    
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_restart.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${process.stdout}
    RW.Core.Add Pre To Report    ${process.stderr}

Scale Up App Service `${APPSERVICE}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Increases the number of workers for the App Service by 1.
    [Tags]    
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_scale_up.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${process.stdout}
    RW.Core.Add Pre To Report    ${process.stderr}


Scale Down App Service `${APPSERVICE}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Decrease the number of workers for the App Service by 1.
    [Tags]    
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_scale_down.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    ${process.stdout}
    RW.Core.Add Pre To Report    ${process.stderr}

*** Keywords ***
Suite Initialization

    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group to perform actions against.
    ...    pattern=\w*
    ${APPSERVICE}=    RW.Core.Import User Variable    APPSERVICE
    ...    type=string
    ...    description=The Azure AppService to triage.
    ...    pattern=\w*
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    Set Suite Variable    ${APPSERVICE}    ${APPSERVICE}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable
    ...    ${env}
    ...    {"APPSERVICE":"${APPSERVICE}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}"}
