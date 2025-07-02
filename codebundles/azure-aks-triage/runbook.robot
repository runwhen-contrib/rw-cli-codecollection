*** Settings ***
Documentation       Runs diagnostic checks against an AKS cluster.
Metadata            Author    stewartshea
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
    [Tags]    aks    config    access:read-only
    ${resource_health}=    RW.CLI.Run Bash File
    ...    bash_file=aks_resource_health.sh
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${resource_health.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat az_resource_health.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0 
        IF    "${issue_list["properties"]["title"]}" != "Available"
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=Azure resources should be available for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
            ...    actual=Azure resources are unhealthy for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
            ...    title=Azure reports an `${issue_list["properties"]["title"]}` Issue for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
            ...    reproduce_hint=${resource_health.cmd}
            ...    details=${issue_list}
            ...    next_steps=Please escalate to the Azure service owner or check back later.
        END
    ELSE
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=Azure resources health should be enabled for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    actual=Azure resource health appears unavailable for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    title=Azure resource health is unavailable for AKS Cluster `${AKS_CLUSTER}` in `${AZ_RESOURCE_GROUP}`
        ...    reproduce_hint=${resource_health.cmd}
        ...    details=${issue_list}
        ...    next_steps=Please escalate to the Azure service owner to enable provider Microsoft.ResourceHealth.
    END


Check Configuration Health of AKS Cluster `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch the config of the AKS cluster in azure
    [Tags]    AKS    config   access:read-only
    ${config}=    RW.CLI.Run Bash File
    ...    bash_file=aks_cluster_health.sh
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${config.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat az_cluster_health.json
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=AKS Cluster `${AKS_CLUSTER}` in resource group `${AZ_RESOURCE_GROUP}` has no configuration issues
            ...    actual=AKS Cluster `${AKS_CLUSTER}` in resource group `${AZ_RESOURCE_GROUP}` has configuration issues
            ...    reproduce_hint=${config.cmd}
            ...    details=${item["details"]}        
        END
    END
Check Network Configuration of AKS Cluster `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`
   [Documentation]    Fetch the network configuration, generating resource URLs and basic recommendations
   [Tags]    AKS    config    network    route    firewall    access:read-only
   ${network}=    RW.CLI.Run Bash File
   ...    bash_file=aks_network.sh
   ...    env=${env}
   ...    timeout_seconds=120
   ...    include_in_history=false
   ...    show_in_rwl_cheatsheet=true
   RW.Core.Add Pre To Report    ${network.stdout}

Fetch Activities for AKS Cluster `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Gets the activities for the AKS cluster set and checks for errors
    [Tags]    AKS    activities    monitor    events    errors    access:read-only
    ${activites}=    RW.CLI.Run Bash File
    ...    bash_file=aks_activities.sh
    ...    env=${env}
    ...    timeout_seconds=60
    ...    include_in_history=false

    RW.Core.Add Pre To Report    ${activites.stdout}

    ${issues}=    RW.CLI.Run Cli    cmd=cat ${OUTPUT DIR}/aks_activities_issues.json
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
    ${AZURE_RESOURCE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_RESOURCE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID for the resource.  
    ...    pattern=\w*
    ...    default=""
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    Set Suite Variable    ${AZURE_RESOURCE_SUBSCRIPTION_ID}    ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AKS_CLUSTER}    ${AKS_CLUSTER}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${TIME_PERIOD_MINUTES}    ${TIME_PERIOD_MINUTES}
    Set Suite Variable
    ...    ${env}
    ...    {"AKS_CLUSTER":"${AKS_CLUSTER}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}", "TIME_PERIOD_MINUTES": "${TIME_PERIOD_MINUTES}", "AZURE_RESOURCE_SUBSCRIPTION_ID":"${AZURE_RESOURCE_SUBSCRIPTION_ID}"}
    # Set Azure subscription context
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    ...    include_in_history=false
