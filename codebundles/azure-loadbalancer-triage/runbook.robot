*** Settings ***
Documentation       Triages issues related to a Azure Loadbalancers and its activity logs.
Metadata            Author    jon-funk
Metadata            Display Name    Azure Internal LoadBalancer Triage
Metadata            Supports    Kubernetes,AKS,Azure

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Check Activity Logs for Azure Load Balancer `${AZ_LB_NAME}`
    [Documentation]    Queries a Azure Loadbalancer's health probe to determine if it's in a healthy state.
    [Tags]    loadbalancer    network    azure    ${az_lb_name}
    ${activity_logs}=    RW.CLI.Run Cli
    ...    cmd=START_TIME=$(date -d "${AZ_HISTORY_RANGE} hours ago" '+%Y-%m-%dT%H:%M:%SZ') && END_TIME=$(date '+%Y-%m-%dT%H:%M:%SZ') && az monitor activity-log list --start-time $START_TIME --end-time $END_TIME --resource-id='${AZ_LB_ID}' --subscription "${AZURE_RESOURCE_SUBSCRIPTION_ID}" | jq -r '.[] | [(.eventTimestamp // "N/A"), (.status.localizedValue // "N/A"), (.subStatus.localizedValue // "N/A"), (.properties.details // "N/A")] | @tsv' | while IFS=$'\t' read -r timestamp status substatus details; do printf "%-30s | %-30s | %-60s | %s\n" "$timestamp" "$status" "$substatus" "$details"; done
    ${activity_logs_report}=    Set Variable    "Azure Load Balancer Health Report:"
    IF    """${activity_logs.stdout}""" == ""
        ${activity_logs_report}=    Set Variable
        ...    "${activity_logs_report}\n\nNo activity log events could be pulled for this resource. If there are events, consider checking the configured time range."
    ELSE
        ${activity_logs_report}=    Set Variable
        ...    "${activity_logs_report}\ntimestamp status substatus details\n${activity_logs.stdout}"
    END
    # Check if activity logs contain critical errors
    ${contains_critical}=    Run Keyword And Return Status    Should Contain    ${activity_logs.stdout}    Critical
    IF    ${contains_critical}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=No activity logs indicating failures for the resource
        ...    actual=Found activity logs indicating the resource has recently experienced an error
        ...    title=Load Balancer `${AZ_LB_NAME}` Activity Log Indicates Recent Errors
        ...    details=Activity Log History\n\n${activity_logs.stdout}
        ...    reproduce_hint=Check Azure activity logs for the load balancer resource
        ...    next_steps=Review the report output and escalate to your service owner.
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${activity_logs_report}
    RW.Core.Add Pre To Report    Commands Used: ${history}


*** Keywords ***
Suite Initialization
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    ${AZ_HISTORY_RANGE}=    RW.Core.Import User Variable
    ...    AZ_HISTORY_RANGE
    ...    type=string
    ...    description=The range of history to check for incidents in the activity log, in hours.
    ...    pattern=\w*
    ...    default=24
    ...    example=24
    ${AZ_LB_NAME}=    RW.Core.Import User Variable
    ...    AZ_LB_NAME
    ...    type=string
    ...    description=The display name of the Azure loadbalancer resource.
    ...    pattern=\w*
    ...    example=kubernetes-internal
    ...    example=kubernetes-internal
    ${AZ_LB_ID}=    RW.Core.Import User Variable
    ...    AZ_LB_ID
    ...    type=string
    ...    description=The ID of the Azure loadbalancer resource, used to map to activity log events.
    ...    pattern=\w*
    ...    example=kubernetes-internal
    ...    example=kubernetes-internal
    ${AZURE_RESOURCE_SUBSCRIPTION_ID}=    RW.Core.Import User Variable    AZURE_RESOURCE_SUBSCRIPTION_ID
    ...    type=string
    ...    description=The Azure Subscription ID for the resource.  
    ...    pattern=\w*
    ...    default=""
    Set Suite Variable    ${AZURE_RESOURCE_SUBSCRIPTION_ID}    ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    Set Suite Variable    ${AZ_HISTORY_RANGE}    ${AZ_HISTORY_RANGE}
    Set Suite Variable    ${AZ_LB_NAME}    ${AZ_LB_NAME}
    Set Suite Variable    ${AZ_LB_ID}    ${AZ_LB_ID}
    # Set Azure subscription context
    RW.CLI.Run Cli
    ...    cmd=az account set --subscription ${AZURE_RESOURCE_SUBSCRIPTION_ID}
    ...    include_in_history=false
