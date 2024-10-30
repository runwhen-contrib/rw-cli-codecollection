*** Settings ***
Documentation       Runs diagnostic checks against an AKS cluster.
Metadata            Author    jon-funk
Metadata            Display Name    Azure AKS Triage
Metadata            Supports    Azure    AKS    Kubernetes    Service    Triage    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Fetch AKS `${AKS_CLUSTER}` Config In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch the config of the AKS cluster in azure
    [Tags]        AKS    config   
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=aks_config.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    IF    ${process.returncode} > 0
        RW.Core.Add Issue    title=Azure Resource `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}` Has Errors In Activities
        ...    severity=3
        ...    next_steps=Review the report details produced by the configuration scan
        ...    expected=Azure Resource `${AKS_CLUSTER}` in resource group `${AZ_RESOURCE_GROUP}` has no misconfiguration(s)
        ...    actual=Azure Resource `${AKS_CLUSTER}` in resource group `${AZ_RESOURCE_GROUP}` has misconfiguration(s)
        ...    reproduce_hint=Run config.sh
        ...    details=${process.stdout}
    END
    RW.Core.Add Pre To Report    ${process.stdout}

Scan AKS `${AKS_CLUSTER}` Activities In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Gets the activities of the AKS cluster.
    [Tags]    AKS    Kubernetes    monitor    events    errors
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=aks_activities.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${next_steps}=    RW.CLI.Run Cli    cmd=echo -e "${process.stdout}" | grep "Next Steps" -A 20 | tail -n +2
    IF    ${process.returncode} > 0
        RW.Core.Add Issue    title=Azure Resource `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}` Has Errors In Activities
        ...    severity=3
        ...    next_steps=${next_steps.stdout}
        ...    expected=Azure Resource `${AKS_CLUSTER}` in resource group `${AZ_RESOURCE_GROUP}` has no errors or criticals in activity logs
        ...    actual=Azure Resource `${AKS_CLUSTER}` in resource group `${AZ_RESOURCE_GROUP}` has errors or critical events in activity logs
        ...    reproduce_hint=Run activities.sh
        ...    details=${process.stdout}
    END
    RW.Core.Add Pre To Report    ${process.stdout}

Validate Cluster `${AKS_CLUSTER}` Configuration In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    performs a validation of the config of the AKS cluster.
    [Tags]    AKS    Kubernetes    monitor    events    errors
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=aks_info.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    IF    ${process.returncode} > 0
        RW.Core.Add Issue    title=AKS Cluster `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}` Has Invalid Config
        ...    severity=2
        ...    next_steps=Review the configuration and agent pool state of the cluster `${AKS_CLUSTER}` in the resource group `${AZ_RESOURCE_GROUP}`
        ...    expected=AKS Cluster `${AKS_CLUSTER}` in resource group `${AZ_RESOURCE_GROUP}` has valid configuration
        ...    actual=AKS Cluster `${AKS_CLUSTER}` in resource group `${AZ_RESOURCE_GROUP}` has invalid configuration
        ...    reproduce_hint=Run aks_info.sh
        ...    details=${process.stdout}
    END
    RW.Core.Add Pre To Report    ${process.stdout}


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