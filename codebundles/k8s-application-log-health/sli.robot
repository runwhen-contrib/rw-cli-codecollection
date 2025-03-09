*** Settings ***
Documentation       Checks for issues in logs from Kubernetes Application Logs fetched through kubectl. Returning 1 when it's healthy and 0 when it's unhealthy.
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes Application Log Health
Metadata            Supports    Kubernetes    Application

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` Logs for Errors in Namespace `${NAMESPACE}`
    [Documentation]    Validates if a Liveliness probe has possible misconfigurations
    [Tags]    kubernetes    logs    errors    exception    ${WORKLOAD_TYPE}
    Scan And Score Issues
    ...    error_log
    ...    scan_error_logs.sh
    ...    scan_error_issues.json
    ...    GenericError,AppFailure


Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` Logs for Stack Traces in Namespace `${NAMESPACE}` 
    [Documentation]   Identifies multi-line stack traces from application failures.
    [Tags]    kubernetes    logs    stacktraces    ${WORKLOAD_TYPE}
    Scan And Score Issues
    ...    stacktrace_log
    ...    scan_stack_traces.sh
    ...    scan_stacktrace_issues.json
    ...    StackTrace


Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` Logs for Connection Failures in Namespace `${NAMESPACE}`
    [Documentation]   Detects errors related to database, API, or network connectivity issues.
    [Tags]    kubernetes    logs    connection    failure    ${WORKLOAD_TYPE}
    Scan And Score Issues
    ...    connection_log
    ...    scan_connection_failures.sh
    ...    scan_conn_issues.json
    ...    Connection

Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` Logs for Timeout Errors in Namespace `${NAMESPACE}`
    [Documentation]   Checks for application logs indicating request timeouts or slow responses.
    [Tags]    kubernetes    logs    timeout    failure    ${WORKLOAD_TYPE}
    Scan And Score Issues
    ...    timeout_log
    ...    scan_timeout_errors.sh
    ...    scan_timeout_issues.json
    ...    Timeout
  
Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` Logs for Authentication and Authorization Failures in Namespace `${NAMESPACE}`
    [Documentation]   Identifies issues where applications fail to authenticate or authorize users/services.
    [Tags]    kubernetes    logs    auth    failure    ${WORKLOAD_TYPE}
    Scan And Score Issues
    ...    auth_log
    ...    scan_auth_failures.sh
    ...    scan_auth_issues.json
    ...    Auth

Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` Logs for Null Pointer and Unhandled Exceptions in Namespace `${NAMESPACE}`
    [Documentation]   Finds critical application crashes due to unhandled exceptions in the code.
    [Tags]    kubernetes    logs    exception    ${WORKLOAD_TYPE}
    Scan And Score Issues
    ...    exception_log
    ...    scan_null_pointer_exceptions.sh
    ...    scan_exception_issues.json
    ...    Exceptions


Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` for Log Anomalies in Namespace `${NAMESPACE}`
    [Documentation]   Detects repeating log messages that may indicate ongoing issues.
    [Tags]    kubernetes    logs    anomaly    ${WORKLOAD_TYPE}
    Scan And Score Issues
    ...    anomaly_log
    ...    scan_log_anomalies.sh
    ...    scan_anomoly_issues.json
    ...    Anomaly
 

Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` Logs for Application Restarts and Failures in Namespace `${NAMESPACE}`
    [Documentation]   Checks logs for indicators of application restarts outside Kubernetes events.
    [Tags]    kubernetes    logs    restart    ${WORKLOAD_TYPE}
    Scan And Score Issues
    ...    app_log
    ...    scan_application_restarts.sh
    ...    scan_application_restarts.json
    ...    AppRestart,AppFailure
 
Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` Logs for Memory and CPU Resource Warnings in Namespace `${NAMESPACE}`
    [Documentation]   Identifies log messages related to high memory or CPU utilization warnings.
    [Tags]    kubernetes    logs    resource    ${WORKLOAD_TYPE}
    Scan And Score Issues
    ...    resource_log
    ...    scan_resource_warnings.sh
    ...    scan_application_restarts.json
    ...    Resource

Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` Logs for Service Dependency Failures in Namespace `${NAMESPACE}`
    [Documentation]   Detects failures when the application cannot reach required services (databases, queues, APIs).
    [Tags]    kubernetes    logs    service    dependency    ${WORKLOAD_TYPE}
    Scan And Score Issues
    ...    dependency_log
    ...    scan_service_dependency_failures.sh
    ...    scan_service_issues.json
    ...    Connection,Timeout,Auth

Generate Application Gateway Health Score
    ${log_score}=      Evaluate  (${error_log_score} + ${stacktrace_log_score} + ${connection_log_score} + ${timeout_log_score} + ${auth_log_score} + ${exception_log_score} + ${anomaly_log_score} + ${app_log_score} + ${resource_log_score} + ${dependency_log_score} ) / 10
    ${health_score}=      Convert to Number    ${log_score}  2
    RW.Core.Push Metric    ${health_score}

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
    ...    default=10m
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
    ...    env={"LOG_AGE":"${LOG_AGE}", "KUBECONFIG":"./${kubeconfig.key}"}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    Set Suite Variable
    ...    ${env}
    ...    {"CURDIR":"${CURDIR}","KUBECONFIG":"./${kubeconfig.key}","WORKLOAD_TYPE":"${WORKLOAD_TYPE}", "WORKLOAD_NAME":"${WORKLOAD_NAME}", "NAMESPACE":"${NAMESPACE}", "CONTEXT":"${CONTEXT}"}

Scan And Score Issues
    [Arguments]    ${TASK}    ${SCAN_SCRIPT}    ${ISSUE_FILE}    ${CATEGORIES}

    ${cli_result}=    RW.CLI.Run Bash File
    ...    bash_file=${SCAN_SCRIPT}
    ...    cmd_override=ISSUE_FILE=${ISSUE_FILE} CATEGORIES=${CATEGORIES} ${SCAN_SCRIPT}
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=False
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=jq '.issues' ${ISSUE_FILE}
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    Set Global Variable     ${${TASK}_score}    1
    IF    len(@{issue_list}) > 0
        FOR    ${item}    IN    @{issue_list}
            IF    ${item["severity"]} < 4
                Set Global Variable    ${${TASK}_score}   0
                Exit For Loop
            ELSE IF    ${item["severity"]} > 2
                Set Global Variable    ${${TASK}_score}   1
            END
        END
    END
