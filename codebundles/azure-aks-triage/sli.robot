*** Settings ***
Documentation       Checks AKS Configuration and returns a 1 when healthy, or 0 when not healthy.
Metadata            Author    jon-funk
Metadata            Display Name    Azure AKS Triage
Metadata            Supports    Azure      AKS    Kubernetes       Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization
*** Tasks ***
Validate Cluster `${AKS_CLUSTER}` Configuration In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Checks AKS cluster configuration.
    [Tags]    AKS       Azure    Metrics    Health
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=aks_info.sh
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
    ${AKS_CLUSTER}=    RW.Core.Import User Variable    AKS_CLUSTER
    ...    type=string
    ...    description=The Azure AKS cluster to triage.
    ...    pattern=\w*
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    Set Suite Variable    ${AKS_CLUSTER}    ${AKS_CLUSTER}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable
    ...    ${env}
    ...    {"AKS_CLUSTER":"${AKS_CLUSTER}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}"}