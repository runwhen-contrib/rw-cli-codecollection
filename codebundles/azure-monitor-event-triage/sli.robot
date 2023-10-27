*** Settings ***
Documentation       Measures the count of error activity log entries as a SLI metric for the Azure tenancy.
Metadata            Author    jon-funk
Metadata            Display Name    Azure Monitor Activity Log SLI
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
    ${activity_logs_count}=    RW.CLI.Run Cli
    ...    cmd=START_TIME=$(date -d "${AZ_HISTORY_RANGE} hours ago" '+%Y-%m-%dT%H:%M:%SZ') && END_TIME=$(date '+%Y-%m-%dT%H:%M:%SZ') && az login --service-principal -u $${AZ_USERNAME.key} -p $${AZ_CLIENT_SECRET.key} --tenant $${AZ_TENANT.key} > /dev/null 2>&1 && az monitor activity-log list --start-time $START_TIME --end-time $END_TIME --status Failed --status Error --status Critical --status "In Progress" | jq -r '. | length'
    ...    secret__az_username=${AZ_USERNAME}
    ...    secret__az_client_secret=${AZ_CLIENT_SECRET}
    ...    secret__az_tenant=${AZ_TENANT}
    ${history}=    RW.CLI.Pop Shell History
    Log    Running: ${history} resulted in the following count: ${activity_logs_count}
    RW.Core.Push Metric    ${activity_logs_count}


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
