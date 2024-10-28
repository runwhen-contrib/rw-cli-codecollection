*** Settings ***
Documentation       Checks VM Scaled Set key metrics and returns a 1 when healthy, or 0 when not healthy.
Metadata            Author    jon-funk
Metadata            Display Name    Azure Virtual Machine Scaled Set Health
Metadata            Supports    Azure    Virtual Machine    Scaled Set    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization
*** Tasks ***
Check Scaled Set `${VMSCALEDSET}` Key Metrics In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks key metrics of VM Scaled Set for issues.
    [Tags]    Scaled Set    VM    Azure    Metrics    Health
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=vmss_metrics.sh
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
    ${VMSCALEDSET}=    RW.Core.Import User Variable    VMSCALEDSET
    ...    type=string
    ...    description=The Azure Virtual Machine Scaled Set to triage.
    ...    pattern=\w*
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    Set Suite Variable    ${VMSCALEDSET}    ${VMSCALEDSET}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable
    ...    ${env}
    ...    {"VMSCALEDSET":"${VMSCALEDSET}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}"}