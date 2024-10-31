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
Check for Resource Health Issues Affecting AKS Cluster `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch a list of issues that might affect the AKS cluster
    [Tags]    aks    config
    ${resource_health}=    RW.CLI.Run Bash File
    ...    bash_file=aks_resource_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/az_resource_health.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    "${issue_list["properties"]["title"]}" != "Available"
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Azure resources should be available for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    actual=Azure resources are unhealthy for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    title= ${issue_list["properties"]["title"]}
        ...    reproduce_hint=${resource_health.cmd}
        ...    details=${issue_list}
        ...    next_steps=Please escalate to the Azure service owner or check back later.
    END
    RW.Core.Add Pre To Report    ${resource_health.stdout}

# Fetch AKS Cluster `${AKS_CLUSTER}` Config In Resource Group `${AZ_RESOURCE_GROUP}`
#    [Documentation]    Fetch the config of the AKS cluster in azure
#    [Tags]    AKS    config
#    ${process}=    RW.CLI.Run Bash File
#    ...    bash_file=aks_config.sh
#    ...    env=${env}
#    ...    timeout_seconds=180
#    ...    include_in_history=false
#    IF    ${process.returncode} > 0
#    RW.Core.Add Issue    title=Azure Resource `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}` Has Errors In Activities
#    ...    severity=3
#    ...    next_steps=Review the report details produced by the configuration scan
#    ...    expected=Azure Resource `${AKS_CLUSTER}` in resource group `${AZ_RESOURCE_GROUP}` has no misconfiguration(s)
#    ...    actual=Azure Resource `${AKS_CLUSTER}` in resource group `${AZ_RESOURCE_GROUP}` has misconfiguration(s)
#    ...    reproduce_hint=Run config.sh
#    ...    details=${process.stdout}
#    END
#    RW.Core.Add Pre To Report    ${process.stdout}

Scan AKS `${AKS_CLUSTER}` Activities In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Gets the activities for the AKS cluster set and checks for errors
    [Tags]    AKS    activities    monitor    events    errors
    ${activites}=    RW.CLI.Run Bash File
    ...    bash_file=aks_activities.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    RW.Core.Add Pre To Report    ${activites.stdout}

    ${issues}=    RW.CLI.Run Cli    cmd=cat ${OUTPUT DIR}/issues.json 
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=AKS Cluster `${AKS_CLUSTER}` in resource group `${AZ_RESOURCE_GROUP}` has no Warning/Error/Critical activities
            ...    actual=AKS Cluster `${AKS_CLUSTER}` in resource group `${AZ_RESOURCE_GROUP}` has Warning/Error/Critical activities
            ...    reproduce_hint=${activites.cmd}
            ...    details=${item["details"]}        
        END
    END


# Validate Cluster `${AKS_CLUSTER}` Configuration In Resource Group `${AZ_RESOURCE_GROUP}`
#    [Documentation]    performs a validation of the config of the AKS cluster.
#    [Tags]    AKS    Kubernetes    monitor    events    errors
#    ${process}=    RW.CLI.Run Bash File
#    ...    bash_file=aks_info.sh
#    ...    env=${env}
#    ...    timeout_seconds=180
#    ...    include_in_history=false
#    IF    ${process.returncode} > 0
#    RW.Core.Add Issue    title=AKS Cluster `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}` Has Invalid Config
#    ...    severity=2
#    ...    next_steps=Review the configuration and agent pool state of the cluster `${AKS_CLUSTER}` in the resource group `${AZ_RESOURCE_GROUP}`
#    ...    expected=AKS Cluster `${AKS_CLUSTER}` in resource group `${AZ_RESOURCE_GROUP}` has valid configuration
#    ...    actual=AKS Cluster `${AKS_CLUSTER}` in resource group `${AZ_RESOURCE_GROUP}` has invalid configuration
#    ...    reproduce_hint=Run aks_info.sh
#    ...    details=${process.stdout}
#    END
#    RW.Core.Add Pre To Report    ${process.stdout}


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
    ${TIME_PERIOD_MINUTES}=    RW.Core.Import User Variable    TIME_PERIOD_MINUTES
    ...    type=string
    ...    description=The time period, in minutes, to look back for activites/events. 
    ...    pattern=\w*
    ...    default=60
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    Set Suite Variable    ${AKS_CLUSTER}    ${AKS_CLUSTER}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${TIME_PERIOD_MINUTES}    ${TIME_PERIOD_MINUTES}
    Set Suite Variable
    ...    ${env}
    ...    {"AKS_CLUSTER":"${AKS_CLUSTER}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}", "OUTPUT_DIR":"${OUTPUT DIR}", "TIME_PERIOD_MINUTES": "${TIME_PERIOD_MINUTES}"}
