*** Settings ***
Documentation       Triages issues related to a Azure Loadbalancers, Kubernetes ingress objects and services.
Metadata            Author    jon-funk
Metadata            Display Name    Azure Monitor Event Triage
Metadata            Supports    Kubernetes,AKS,Azure

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Run Azure Monitor Activity Log Triage
    [Documentation]    Queries a Azure Loadbalancer's health probe to determine if it's in a healthy state.
    [Tags]    load    balancer    azure
    ${activity_logs}=    RW.CLI.Run Cli
    ...    cmd=START_TIME=$(date -d "${AZ_HISTORY_RANGE} hours ago" '+%Y-%m-%dT%H:%M:%SZ') && END_TIME=$(date '+%Y-%m-%dT%H:%M:%SZ') && az login --service-principal -u $${AZ_USERNAME.key} -p $${AZ_CLIENT_SECRET.key} --tenant $${AZ_TENANT.key} > /dev/null 2>&1 && az monitor activity-log list --start-time $START_TIME --end-time $END_TIME | jq -r '.[] | [(.eventTimestamp // "N/A"), (.status.localizedValue // "N/A"), (.subStatus.localizedValue // "N/A"), (.properties.details // "N/A")] | @tsv' | while IFS=$'\t' read -r timestamp status substatus details; do printf "%-30s | %-30s | %-60s | %s\n" "$timestamp" "$status" "$substatus" "$details"; done
    ...    secret__az_username=${AZ_USERNAME}
    ...    secret__az_client_secret=${AZ_CLIENT_SECRET}
    ...    secret__az_tenant=${AZ_TENANT}
    ${activity_logs_report}=    Set Variable    "Azure Monitor Activity Log Report:"
    IF    """${activity_logs.stdout}""" == ""
        ${activity_logs_report}=    Set Variable
        ...    "${activity_logs_report}\n\nNo activity log events could be pulled in the Azure Tenancy."
    ELSE
        ${activity_logs_report}=    Set Variable
        ...    "${activity_logs_report}\ntimestamp status substatus details\n${activity_logs.stdout}"
    END
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${activity_logs}
    ...    set_severity_level=2
    ...    set_issue_expected=No activity logs indicating failures for the resource.
    ...    set_issue_actual=Found activity logs indicating the resource has recently experienced an error.
    ...    set_issue_title=Azure Monitor Activity Log Indicates Recent Errors
    ...    set_issue_details=Activity Log History\n\n${activity_logs.stdout}
    ...    set_issue_next_steps=Inspect the status, substatus, and details of the activity log report for more details.
    ...    _line__raise_issue_if_contains=Critical
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${activity_logs_report}
    RW.Core.Add Pre To Report    Commands Used: ${history}


*** Keywords ***
Suite Initialization
    ${AZ_USERNAME}=    RW.Core.Import Secret
    ...    AZ_USERNAME
    ...    type=string
    ...    description=The azure service principal user ID.
    ...    pattern=\w*
    ${AZ_CLIENT_SECRET}=    RW.Core.Import Secret
    ...    AZ_CLIENT_SECRET
    ...    type=string
    ...    description=The service principal client secret used to authenticate with azure.
    ...    pattern=\w*
    ${AZ_TENANT}=    RW.Core.Import Secret
    ...    AZ_TENANT
    ...    type=string
    ...    description=The azure tenant ID used by the service principal to authenticate with azure.
    ...    pattern=\w*
    ${AZ_HISTORY_RANGE}=    RW.Core.Import User Variable
    ...    AZ_HISTORY_RANGE
    ...    type=string
    ...    description=The range of history to check for incidents in the activity log, in hours.
    ...    pattern=\w*
    ...    default=24
    ...    example=24
    Set Suite Variable    ${AZ_USERNAME}    ${AZ_USERNAME}
    Set Suite Variable    ${AZ_CLIENT_SECRET}    ${AZ_CLIENT_SECRET}
    Set Suite Variable    ${AZ_TENANT}    ${AZ_TENANT}
    Set Suite Variable    ${AZ_HISTORY_RANGE}    ${AZ_HISTORY_RANGE}
