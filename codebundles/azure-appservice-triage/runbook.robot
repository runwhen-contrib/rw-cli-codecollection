*** Settings ***
Documentation       Triages an azure appservice and its workloads, checking its status and logs.
Metadata            Author    jon-funk
Metadata            Display Name    Azure AppService Triage
Metadata            Supports    Azure    AppService    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check AppService `${APPSERVICE}` Health Status In Resource Group `${RESOURCE_GROUP}`
    [Documentation]    Checks the health status of a appservice workload.
    [Tags]    
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_health.sh
    ...    env=${env}
    ...    secret__az_username=${AZ_USERNAME}
    ...    secret__az_client_secret=${AZ_CLIENT_SECRET}
    ...    secret__az_tenant=${AZ_TENANT}
    ...    timeout_seconds=180
    ...    include_in_history=false
    # IF    ${process.returncode} > 0
    #     RW.Core.Add Issue    title=OpenTelemetry Span Queue Growing
    #     ...    severity=3
    #     ...    next_steps=Check OpenTelemetry backend is available in `${NAMESPACE}` and that the collector has enough resources, and that the collector's configmap is up-to-date.
    #     ...    expected=Queue size for spans should not be past threshold of 500
    #     ...    actual=Queue size of 500 or larger found
    #     ...    reproduce_hint=Run otel_metrics_check.sh
    #     ...    details=${process.stdout}
    # END
    RW.Core.Add Pre To Report    ${process.stdout}\n

Get AppService `${APPSERVICE}` Logs In Resource Group `${RESOURCE_GROUP}`
    [Documentation]    Fetch logs of appservice workload
    [Tags]    appservice    logs    tail
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_logs.sh
    ...    env=${env}
    ...    secret__az_username=${AZ_USERNAME}
    ...    secret__az_client_secret=${AZ_CLIENT_SECRET}
    ...    secret__az_tenant=${AZ_TENANT}
    ...    timeout_seconds=180
    ...    include_in_history=false
    # IF    ${process.returncode} > 0
    #     RW.Core.Add Issue    title=OpenTelemetry Collector Has Error Logs
    #     ...    severity=3
    #     ...    next_steps=Tail OpenTelemetry Collector Logs In Namespace `${NAMESPACE}` For Stacktraces
    #     ...    expected=Logs do not contain errors
    #     ...    actual=Found error logs
    #     ...    reproduce_hint=Run otel_error_check.sh
    #     ...    details=${process.stdout}
    # END
    RW.Core.Add Pre To Report    ${process.stdout}\n

Scan AppService `${APPSERVICE}` Event Errors In Resource Group `${RESOURCE_GROUP}`
    [Documentation]    Gets the events of appservice and checks for errors
    [Tags]    appservice    monitor    events    errors
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_events.sh
    ...    env=${env}
    ...    secret__az_username=${AZ_USERNAME}
    ...    secret__az_client_secret=${AZ_CLIENT_SECRET}
    ...    secret__az_tenant=${AZ_TENANT}
    ...    timeout_seconds=180
    ...    include_in_history=false
    # IF    ${process.returncode} > 0
    #     RW.Core.Add Issue    title=OpenTelemetry Collector Logs Have Dropped Spans
    #     ...    severity=3
    #     ...    next_steps=Tail OpenTelemetry Collector Logs In Namespace `${NAMESPACE}` For Stacktraces
    #     ...    expected=Logs do not contain dropped span entries
    #     ...    actual=Found dropped span entries
    #     ...    reproduce_hint=Run otel_dropped_check.sh
    #     ...    details=${process.stdout}
    # END
    RW.Core.Add Pre To Report    ${process.stdout}\n

*** Keywords ***
Suite Initialization
    ${AZ_USERNAME}=    RW.Core.Import Secret
    ...    AZ_USERNAME
    ...    type=string
    ...    description=The azure service principal client ID on the app registration.
    ...    pattern=\w*
    ${AZ_SECRET_VALUE}=    RW.Core.Import Secret
    ...    AZ_SECRET_VALUE
    ...    type=string
    ...    description=The service principal secret value on the associated credential for the app registration.
    ...    pattern=\w*
    ${AZ_TENANT}=    RW.Core.Import Secret
    ...    AZ_TENANT
    ...    type=string
    ...    description=The azure tenant ID used by the service principal to authenticate with azure.
    ...    pattern=\w*
    ${AZ_SUBSCRIPTION}=    RW.Core.Import Secret
    ...    AZ_SUBSCRIPTION
    ...    type=string
    ...    description=The azure tenant ID used by the service principal to authenticate with azure.
    ...    pattern=\w*
    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group to perform actions against.
    ...    pattern=\w*
    ${APPSERVICE}=    RW.Core.Import User Variable    APPSERVICE
    ...    type=string
    ...    description=The Azure AppService to triage.
    ...    pattern=\w*

    Set Suite Variable    ${APPSERVICE}    ${APPSERVICE}
    Set Suite Variable    ${RESOURCE_GROUP}    ${RESOURCE_GROUP}
    Set Suite Variable    ${AZ_USERNAME}    ${AZ_USERNAME}
    Set Suite Variable    ${AZ_SECRET_VALUE}    ${AZ_SECRET_VALUE}
    Set Suite Variable    ${AZ_TENANT}    ${AZ_TENANT}
    Set Suite Variable    ${AZ_SUBSCRIPTION}    ${AZ_SUBSCRIPTION}
    Set Suite Variable
    ...    ${env}
    ...    {"APPSERVICE":"${APPSERVICE}", "RESOURCE_GROUP":"${RESOURCE_GROUP}"}
