*** Settings ***
Documentation       Checks the key metrics of a azure data factory and returns a 1 when healthy, or 0 when not healthy.
Metadata            Author    jon-funk
Metadata            Display Name    Azure ADF Triage
Metadata            Supports    Azure      ADF    Data Factory       Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization
*** Tasks ***
Health Check Key ADF `${ADF}` Metrics In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks the key metrics of a ADF workload.
    [Tags]    ADF       Azure    Metrics    Health
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=adf_metrics.sh
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
    ${ADF}=    RW.Core.Import User Variable    ADF
    ...    type=string
    ...    description=The Azure data factory to triage.
    ...    pattern=\w*
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    Set Suite Variable    ${ADF}    ${ADF}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable
    ...    ${env}
    ...    {"ADF":"${ADF}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}"}