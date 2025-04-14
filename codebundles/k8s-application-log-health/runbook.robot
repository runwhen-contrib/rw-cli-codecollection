*** Settings ***
Documentation       Analyzes logs from Kubernetes Application Logs fetched through kubectl
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes Application Log Health
Metadata            Supports    Kubernetes    Application

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             Process
Library             OperatingSystem


Suite Setup         Suite Initialization

*** Tasks ***
Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` Logs for Errors in Namespace `${NAMESPACE}`
    [Documentation]    Validates if a Liveliness probe has possible misconfigurations
    [Tags]    access:read-only    kubernetes    logs    errors    exception    ${WORKLOAD_TYPE}
    Scan And Report Issues
    ...    scan_error_logs.sh
    ...    scan_error_issues.json
    ...    GenericError,AppFailure

Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` Logs for Stack Traces in Namespace `${NAMESPACE}` 
    [Documentation]   Identifies multi-line stack traces from application failures.
    [Tags]    access:read-only    kubernetes    logs    stacktraces    ${WORKLOAD_TYPE}
    Scan And Report Issues
    ...    scan_stack_traces.sh
    ...    scan_stacktrace_issues.json
    ...    StackTrace

Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` Logs for Connection Failures in Namespace `${NAMESPACE}`
    [Documentation]   Detects errors related to database, API, or network connectivity issues.
    [Tags]    access:read-only    kubernetes    logs    connection    failure    ${WORKLOAD_TYPE}
    Scan And Report Issues
    ...    scan_connection_failures.sh
    ...    scan_conn_issues.json
    ...    Connection

Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` Logs for Timeout Errors in Namespace `${NAMESPACE}`
    [Documentation]   Checks for application logs indicating request timeouts or slow responses.
    [Tags]    access:read-only    kubernetes    logs    timeout    failure    ${WORKLOAD_TYPE}
    Scan And Report Issues
    ...    scan_timeout_errors.sh
    ...    scan_timeout_issues.json
    ...    Timeout
  
Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` Logs for Authentication and Authorization Failures in Namespace `${NAMESPACE}`
    [Documentation]   Identifies issues where applications fail to authenticate or authorize users/services.
    [Tags]    access:read-only    kubernetes    logs    auth    failure    ${WORKLOAD_TYPE}
    Scan And Report Issues
    ...    scan_auth_failures.sh
    ...    scan_auth_issues.json
    ...    Auth

Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` Logs for Null Pointer and Unhandled Exceptions in Namespace `${NAMESPACE}`
    [Documentation]   Finds critical application crashes due to unhandled exceptions in the code.
    [Tags]    access:read-only    kubernetes    logs    exception    ${WORKLOAD_TYPE}
    Scan And Report Issues
    ...    scan_null_pointer_exceptions.sh
    ...    scan_exception_issues.json
    ...    Exceptions

Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` for Log Anomalies in Namespace `${NAMESPACE}`
    [Documentation]   Detects repeating log messages that may indicate ongoing issues.
    [Tags]    access:read-only    kubernetes    logs    anomaly    ${WORKLOAD_TYPE}
    Scan And Report Issues
    ...    scan_log_anomalies.sh
    ...    scan_anomoly_issues.json
    ...    Anomaly
 

Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` Logs for Application Restarts and Failures in Namespace `${NAMESPACE}`
    [Documentation]   Checks logs for indicators of application restarts outside Kubernetes events.
    [Tags]    access:read-only    kubernetes    logs    restart    ${WORKLOAD_TYPE}
    Scan And Report Issues
    ...    scan_application_restarts.sh
    ...    scan_application_restarts.json
    ...    AppRestart,AppFailure
 
Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` Logs for Memory and CPU Resource Warnings in Namespace `${NAMESPACE}`
    [Documentation]   Identifies log messages related to high memory or CPU utilization warnings.
    [Tags]    access:read-only    kubernetes    logs    resource    ${WORKLOAD_TYPE}
    Scan And Report Issues
    ...    scan_application_restarts.sh
    ...    scan_application_restarts.json
    ...    Resource

Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` Logs for Service Dependency Failures in Namespace `${NAMESPACE}`
    [Documentation]   Detects failures when the application cannot reach required services (databases, queues, APIs).
    [Tags]    access:read-only    kubernetes    logs    service    dependency    ${WORKLOAD_TYPE}
    Scan And Report Issues
    ...    scan_service_dependency_failures.sh
    ...    scan_service_issues.json
    ...    Connection,Timeout,Auth

*** Keywords ***
Suite Initialization
   ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=The name of the Kubernetes namespace to scope actions and searching to. Accepts a single namespace in the format `-n namespace-name` or `--all-namespaces`. 
    ...    pattern=\w*
    ...    example=-n my-namespace
    ...    default=--all-namespaces
    ${WORKLOAD_TYPE}=    RW.Core.Import User Variable    WORKLOAD_TYPE
    ...    type=string
    ...    description=The type of Kubernetes resource to analyze (e.g. Deployment, StatefulSet, Daemonset, and so on.)
    ...    pattern=\w*
    ...    example=deployment
    ...    default=deployment
    ${WORKLOAD_NAME}=    RW.Core.Import User Variable    WORKLOAD_NAME
    ...    type=string
    ...    description=The name of the Kubernetes application to analyze. 
    ...    pattern=\w*
    ...    example=cartservice
    ...    default=
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    default=default
    ...    example=my-main-cluster
    ${LOG_AGE}=    RW.Core.Import User Variable    LOG_AGE
    ...    type=string
    ...    description=Only return logs newer than a relative duration like 5s, 2m, or 3h.
    ...    pattern=\w*
    ...    default=1h
    ...    example=5s,10m,1h
    Set Suite Variable    ${LOG_AGE}    ${LOG_AGE}
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${WORKLOAD_TYPE}    ${WORKLOAD_TYPE}
    Set Suite Variable    ${WORKLOAD_NAME}    ${WORKLOAD_NAME}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}

    ${pods}=    RW.CLI.Run Bash File
    ...    bash_file=get_pod_logs_for_workload.sh
    ...    cmd_override=./get_pod_logs_for_workload.sh ${WORKLOAD_TYPE} ${WORKLOAD_NAME} ${NAMESPACE} ${CONTEXT}
    ...    env={"LOG_AGE":"${LOG_AGE}","KUBECONFIG":"./${kubeconfig.key}"}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}","WORKLOAD_TYPE":"${WORKLOAD_TYPE}", "WORKLOAD_NAME":"${WORKLOAD_NAME}", "NAMESPACE":"${NAMESPACE}", "CONTEXT":"${CONTEXT}"}

Scan And Report Issues
    [Arguments]    ${SCAN_SCRIPT}    ${ISSUE_FILE}    ${CATEGORIES}

    ${cli_result}=    RW.CLI.Run Bash File
    ...    bash_file=${SCAN_SCRIPT}
    ...    cmd_override=ISSUE_FILE=${ISSUE_FILE} CATEGORIES=${CATEGORIES} ${SCAN_SCRIPT}
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=False
    Add Pre To Report    Report Output:\n${cli_result.stdout}

    ${summary}=    RW.CLI.Run Cli
    ...    cmd=jq '.summary[]' ${ISSUE_FILE}
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    Add Pre To Report    Summary:\n${summary.stdout}

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=jq '.issues' ${ISSUE_FILE}
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0
        FOR    ${item}    IN    @{issue_list}
            ${contents}=     RW.CLI.Run Cli
            ...    cmd=echo "${item['details']}" > ${SCAN_SCRIPT}_details.log
            ${log_summary}=    RW.CLI.Run Cli
            ...    cmd=python3 summarize.py < ${CURDIR}/${SCAN_SCRIPT}_details.log

            ${next_steps}=    Catenate    SEPARATOR=\n   @{item["next_steps"]}

            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${next_steps}
            ...    expected=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` namespace `${NAMESPACE}` has no errors
            ...    actual=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` namespace `${NAMESPACE}` has errors
            ...    reproduce_hint=${cli_result.cmd}
            ...    details=${log_summary.stdout}        
        END
    END   