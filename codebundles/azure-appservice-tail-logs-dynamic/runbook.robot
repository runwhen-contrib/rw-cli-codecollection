*** Settings ***
Documentation       Performs application-level troubleshooting by inspecting the logs of a workload for parsable exceptions,
...                 and attempts to determine next steps.
Metadata            Author    jon-funk
Metadata            Display Name    Azure App Service Tail Application Logs
Metadata            Supports    Azure    App Service    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.K8sApplications


Suite Setup         Suite Initialization


*** Tasks ***
Get AppService `${APPSERVICE}` Logs In Resource Group `${AZ_RESOURCE_GROUP}`
    [Documentation]    Fetch logs of appservice workload
    [Tags]    appservice    logs    tail
    ${process}=    RW.CLI.Run Bash File
    ...    bash_file=appservice_logs.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    RW.Core.Add Pre To Report    Workload Logs:\n\n${process.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Tail AppService `${APPSERVICE}` Application Logs For Stacktraces
    [Documentation]    Performs an inspection on container logs for exceptions/stacktraces, parsing them and attempts to find relevant source code information
    [Tags]
    ...    application
    ...    debug
    ...    app
    ...    errors
    ...    troubleshoot
    ...    workload
    ...    api
    ...    logs
    ...    ${container_name}
    ...    ${workload_name}
    ${cmd}=    Set Variable
    ...    az webapp log download --name ${APPSERVICE} --resource-group ${AZ_RESOURCE_GROUP} --log-file /tmp/az_app_service_log && unzip -qq -c /tmp/az_app_service_log
    IF    $EXCLUDE_PATTERN != ""
        ${cmd}=    Set Variable
        ...    ${cmd} | grep -Ev "${EXCLUDE_PATTERN}" || true
    END
    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${cmd}
    ...    env=${env}
    ${parsed_stacktraces}=    RW.K8sApplications.Dynamic Parse Stacktraces    ${logs.stdout}
    ...    parser_name=${STACKTRACE_PARSER}
    ...    parse_mode=${INPUT_MODE}
    ...    show_debug=True
    ${report_data}=    RW.K8sApplications.Stacktrace Report Data   stacktraces=${parsed_stacktraces}
    ${report}=    Set Variable    ${report_data["report"]}
    ${history}=    RW.CLI.Pop Shell History
    IF    (len($parsed_stacktraces)) > 0
        ${mcst}=    Set Variable    ${report_data["most_common_stacktrace"]}
        ${first_file}=    Set Variable    ${mcst.get_first_file_line_nums_as_str()}
        RW.Core.Add Issue
        ...    severity=3
        ...    expected=No stacktraces were found in the application logs of ${APPSERVICE}
        ...    actual=Found stacktraces in the application logs of ${APPSERVICE}
        ...    reproduce_hint=Run:\n${cmd}\n view logs results for stacktraces.
        ...    title=Stacktraces Found In Tailed Logs Of `${APPSERVICE}`
        ...    details=Generated a report of the stacktraces found to be reviewed.
        ...    next_steps=Check this file ${first_file} for the most common stacktrace and review the full report for more details.
    END
    RW.Core.Add Pre To Report    ${report}
    RW.Core.Add Pre To Report    Commands Used: ${history}






*** Keywords ***
Suite Initialization
    ${azure_credentials}=    RW.Core.Import Secret
    ...    azure_credentials
    ...    type=string
    ...    description=The secret containing AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_CLIENT_SECRET, AZURE_SUBSCRIPTION_ID
    ...    pattern=\w*
    ${AZ_RESOURCE_GROUP}=    RW.Core.Import User Variable    AZ_RESOURCE_GROUP
    ...    type=string
    ...    description=The resource group to perform actions against.
    ...    pattern=\w*
    ${APPSERVICE}=    RW.Core.Import User Variable    APPSERVICE
    ...    type=string
    ...    description=The Azure AppService to triage.
    ...    pattern=\w*
    ${EXCLUDE_PATTERN}=    RW.Core.Import User Variable
    ...    EXCLUDE_PATTERN
    ...    type=string
    ...    description=Grep pattern to use to exclude exceptions that don't indicate a critical issue.
    ...    pattern=\w*
    ...    example=FalseError|SecondErrorToSkip
    ...    default=FalseError|SecondErrorToSkip
    ${STACKTRACE_PARSER}=    RW.Core.Import User Variable    STACKTRACE_PARSER
    ...    type=string
    ...    enum=[Dynamic,GoLang,GoLangJson,CSharp,Python,Django,DjangoJson]
    ...    description=What parser implementation to use when going through logs. Dynamic will use the first successful parser which is more computationally expensive.
    ...    default=Dynamic
    ...    example=Dynamic
    ${INPUT_MODE}=    RW.Core.Import User Variable    INPUT_MODE
    ...    type=string
    ...    enum=[SPLIT,MULTILINE]
    ...    description=Changes ingestion style of logs, typically split (1 log per line) works best.
    ...    default=SPLIT
    ...    example=SPLIT
    Set Suite Variable    ${APPSERVICE}    ${APPSERVICE}
    Set Suite Variable    ${AZ_RESOURCE_GROUP}    ${AZ_RESOURCE_GROUP}
    Set Suite Variable    ${INPUT_MODE}    ${INPUT_MODE}
    Set Suite Variable    ${STACKTRACE_PARSER}    ${STACKTRACE_PARSER}
    Set Suite Variable    ${EXCLUDE_PATTERN}    ${EXCLUDE_PATTERN}

    Set Suite Variable
    ...    ${env}
    ...    {"APPSERVICE":"${APPSERVICE}", "AZ_RESOURCE_GROUP":"${AZ_RESOURCE_GROUP}"}
