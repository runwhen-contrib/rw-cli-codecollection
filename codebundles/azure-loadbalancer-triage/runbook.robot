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
    [Tags]    loadbalancer    network    azure    ${AZ_LB_NAME}
    ${lb_id}=    RW.CLI.Run Cli
    ...    cmd=source $AZURE_CREDENTIALS && az login --service-principal -u $AZURE_CLIENT_ID -p $AZURE_CLIENT_SECRET --tenant $AZURE_TENANT_ID > /dev/null 2>&1 && az network lb list --query "[?name=='${AZ_LB_NAME}']" | jq -r '.[0].id'
    ...    secret_file__azure_credentials=${azure_credentials}
    ...    env=${env}
    ${activity_logs}=    RW.CLI.Run Cli
    ...    cmd=source $AZURE_CREDENTIALS && START_TIME=$(date -d "${AZ_HISTORY_RANGE} hours ago" '+%Y-%m-%dT%H:%M:%SZ') && END_TIME=$(date '+%Y-%m-%dT%H:%M:%SZ') az login --service-principal -u $AZURE_CLIENT_ID -p $AZURE_CLIENT_SECRET --tenant $AZURE_TENANT_ID > /dev/null 2>&1 && az monitor activity-log list --start-time $START_TIME --end-time $END_TIME --query "[?resourceType.value=='MICROSOFT.NETWORK/loadbalancers' && resourceId=='${lb_id.stdout}']" | jq -r '.[] | [(.eventTimestamp // "N/A"), (.status.localizedValue // "N/A"), (.subStatus.localizedValue // "N/A"), (.properties.details // "N/A")] | @tsv' | while IFS=$'\t' read -r timestamp status substatus details; do printf "%-30s | %-30s | %-60s | %s\n" "$timestamp" "$status" "$substatus" "$details"; done
    ...    secret_file__azure_credentials=${azure_credentials}
    ...    env=${env}
    ${activity_logs_report}=    Set Variable    "Azure Load Balancer Health Report:"
    IF    """${activity_logs.stdout}""" == ""
        ${activity_logs_report}=    Set Variable
        ...    "${activity_logs_report}\n\nNo activity log events could be pulled for this resource. If there are events, consider checking the configured time range."
    ELSE
        ${activity_logs_report}=    Set Variable
        ...    "${activity_logs_report}\ntimestamp status substatus details\n${activity_logs.stdout}"
    END
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${activity_logs}
    ...    set_severity_level=2
    ...    set_issue_expected=No activity logs indicating failures for the resource.
    ...    set_issue_actual=Found activity logs indicating the resource has recently experienced an error.
    ...    set_issue_title=Load Balancer Activity Log Indicates Recent Errors
    ...    set_issue_details=Activity Log History\n\n${activity_logs.stdout}
    ...    set_issue_next_steps=Review the report output and escalate to your service owner. 
    ...    _line__raise_issue_if_contains=Critical
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
    ...    description=The name of the Azure loadbalancer resource, used to map to activity log events.
    ...    pattern=\w*
    ...    example=kubernetes-internal
    ...    example=kubernetes-internal
    Set Suite Variable    ${azure_credentials}    ${azure_credentials}    
    Set Suite Variable    ${AZ_HISTORY_RANGE}    ${AZ_HISTORY_RANGE}
    Set Suite Variable    ${AZ_LB_NAME}    ${AZ_LB_NAME}
    Set Suite Variable    ${env}    {"AZURE_CREDENTIALS":"./${azure_credentials.key}"}

