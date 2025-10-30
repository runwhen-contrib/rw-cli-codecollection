*** Settings ***
Documentation       Generates a composite score about the health of an AKS cluster using the AZ CLI. Returns a 1 if all checks pass, 0 if they all fail, and value between 0 and 1 for partial success/fail. Checks the upstream service for reported errors. Looks for Critical or Error activities within a specified time period. Checks the overall configuration for provisioning failures. 
Metadata            Author    stewartshea
Metadata            Display Name    Azure AKS Triage
Metadata            Supports    Azure    AKS    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization
*** Tasks ***
Check for Resource Health Issues Affecting AKS Cluster `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch a list of issues that might affect the AKS cluster as reported from Azure. 
    [Tags]    aks    resource    health    service    azure
    ${resource_health}=    RW.CLI.Run Bash File
    ...    bash_file=aks_resource_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true

    ${resource_health_output}=    RW.CLI.Run Cli
    ...    cmd=cat az_resource_health.json | tr -d '\n'
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${resource_health_output_json}=    Evaluate    json.loads(r'''${resource_health_output.stdout}''')    json
    IF    len(@{resource_health_output_json}) > 0 
        ${aks_resource_score}=    Evaluate    1 if "${resource_health_output_json["properties"]["title"]}" == "Available" else 0
    ELSE
        ${aks_resource_score}=    Set Variable    0
    END
    Set Global Variable    ${aks_resource_score}
    RW.Core.Push Metric    ${aks_resource_score}    sub_name=resource_health


Fetch Activities for AKS Cluster `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Gets the activities for the AKS cluster set and checks for critical or error events within the configured time period.
    [Tags]    AKS    activities    monitor    events    errors    critical
    ${activites}=    RW.CLI.Run Bash File
    ...    bash_file=aks_activities.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false

    ${issues}=    RW.CLI.Run Cli    
    ...    cmd=cat aks_activities_issues.json
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    Set Global Variable     ${aks_activities_score}    1
    IF    len(@{issue_list["issues"]}) > 0
        FOR    ${item}    IN    @{issue_list["issues"]}
            IF    ${item["severity"]} == 1 or ${item["severity"]} == 2
                Set Global Variable    ${aks_activities_score}    0
                Exit For Loop
            ELSE IF    ${item["severity"]} > 2
                Set Global Variable    ${aks_activities_score}    1
            END
        END
    END
    RW.Core.Push Metric    ${aks_activities_score}    sub_name=activities

Check Configuration Health of AKS Cluster `${AKS_CLUSTER}` In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch the config of the AKS cluster in azure
    [Tags]    AKS    config
    ${config}=    RW.CLI.Run Bash File
    ...    bash_file=aks_cluster_health.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat az_cluster_health.json | jq '{issues: [.issues[] | select(.severity < 4)]}'
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    ${aks_config_score}=    Evaluate    1 if len(@{issue_list["issues"]}) == 0 else 0
    Set Global Variable    ${aks_config_score}
    RW.Core.Push Metric    ${aks_config_score}    sub_name=configuration

Generate AKS Cluster Health Score
    ${aks_cluster_health_score}=      Evaluate  (${aks_resource_score} + ${aks_activities_score} + ${aks_config_score}) / 3
    ${health_score}=      Convert to Number    ${aks_cluster_health_score}  2
    RW.Core.Push Metric    ${health_score}

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
    ${AZURE_RESOURCE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_RESOURCE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID for the resource.  
    ...    pattern=\w*
    ${RW_LOOKBACK_WINDOW}=    RW.Core.Import Platform Variable    RW_LOOKBACK_WINDOW
    ${RW_LOOKBACK_WINDOW}=    RW.Core.Normalize Lookback Window    ${RW_LOOKBACK_WINDOW}    1
    Set Suite Variable    ${AZURE_RESOURCE_SUBSCRIPTION_ID}    ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AKS_CLUSTER}    ${AKS_CLUSTER}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${RW_LOOKBACK_WINDOW}    ${RW_LOOKBACK_WINDOW}
    Set Suite Variable
    ...    ${env}
    ...    {"AKS_CLUSTER":"${AKS_CLUSTER}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}", "RW_LOOKBACK_WINDOW": "${RW_LOOKBACK_WINDOW}", "AZURE_RESOURCE_SUBSCRIPTION_ID":"${AZURE_RESOURCE_SUBSCRIPTION_ID}"}
    # Set Azure subscription context
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    ...    include_in_history=false