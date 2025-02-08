*** Settings ***
Documentation       Checks for issues in logs from Kubernetes Application Logs fetched through kubectl. Returning 1 when it's healthy and 0 when it's unhealthy.
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes Application Log Health
Metadata            Supports    Kubernetes    Application

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` ERROR Logs in Namespace `${NAMESPACE}`
    [Documentation]    Validates if a Liveliness probe has possible misconfigurations
    [Tags]    kubernetes    logs    errors    exception    ${WORKLOAD_TYPE}
    Scan And Score Issues
    ...    error_log
    ...    scan_error_logs.sh
    ...    scan_error_issues.json


Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` for Stack Traces in Namespace `${NAMESPACE}` 
    [Documentation]   Identifies multi-line stack traces from application failures.
    [Tags]    kubernetes    logs    stacktraces    ${WORKLOAD_TYPE}
    Scan And Score Issues
    ...    stacktrace_log
    ...    scan_stack_traces.sh
    ...    scan_stacktrace_issues.json


Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` for Connection Failures in Namespace `${NAMESPACE}`
    [Documentation]   Detects errors related to database, API, or network connectivity issues.
    [Tags]    kubernetes    logs    connection    failure    ${WORKLOAD_TYPE}
    Scan And Score Issues
    ...    connection_log
    ...    scan_connection_failures.sh
    ...    scan_conn_issues.json

Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` for Timeout Errors in Namespace `${NAMESPACE}`
    [Documentation]   Checks for application logs indicating request timeouts or slow responses.
    [Tags]    kubernetes    logs    timeout    failure    ${WORKLOAD_TYPE}
    Scan And Score Issues
    ...    timeout_log
    ...    scan_timeout_errors.sh
    ...    scan_timeout_issues.json
  
Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` for Authentication and Authorization Failures in Namespace `${NAMESPACE}`
    [Documentation]   Identifies issues where applications fail to authenticate or authorize users/services.
    [Tags]    kubernetes    logs    auth    failure    ${WORKLOAD_TYPE}
    Scan And Score Issues
    ...    auth_log
    ...    scan_auth_failures.sh
    ...    scan_auth_issues.json

Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` for Null Pointer and Unhandled Exceptions in Namespace `${NAMESPACE}`
    [Documentation]   Finds critical application crashes due to unhandled exceptions in the code.
    [Tags]    kubernetes    logs    exception    ${WORKLOAD_TYPE}
    Scan And Score Issues
    ...    exception_log    
    ...    scan_null_pointer_exceptions.sh
    ...    scan_exception_issues.json


Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` for Log Anomalies in Namespace `${NAMESPACE}`
    [Documentation]   Detects repeating log messages that may indicate ongoing issues.
    [Tags]    kubernetes    logs    anomaly    ${WORKLOAD_TYPE}
    Scan And Score Issues
    ...    anomaly_log
    ...    scan_log_anomalies.sh
    ...    scan_anomoly_issues.json
 

Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` for Application Restarts and Failures in Namespace `${NAMESPACE}`
    [Documentation]   Checks logs for indicators of application restarts outside Kubernetes events.
    [Tags]    kubernetes    logs    restart    ${WORKLOAD_TYPE}
    Scan And Score Issues
    ...    app_log
    ...    scan_application_restarts.sh
    ...    scan_application_restarts.json
 
Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` for Memory and CPU Resource Warnings in Namespace `${NAMESPACE}`
    [Documentation]   Identifies log messages related to high memory or CPU utilization warnings.
    [Tags]    kubernetes    logs    resource    ${WORKLOAD_TYPE}
    Scan And Score Issues
    ...    resource_log
    ...    scan_resource_warnings.sh
    ...    scan_resource_issues.json

Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` for Service Dependency Failures in Namespace `${NAMESPACE}`
    [Documentation]   Detects failures when the application cannot reach required services (databases, queues, APIs).
    [Tags]    kubernetes    logs    service    dependency    ${WORKLOAD_TYPE}
    Scan And Score Issues
    ...    dependency_log
    ...    scan_service_dependency_failures.sh
    ...    scan_service_issues.json

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
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${WORKLOAD_TYPE}    ${WORKLOAD_TYPE}
    Set Suite Variable    ${WORKLOAD_NAME}    ${WORKLOAD_NAME}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}

    ${pods}=    RW.CLI.Run Bash File
    ...    bash_file=get_pod_logs_for_workload.sh
    ...    cmd_override=./get_pod_logs_for_workload.sh ${WORKLOAD_TYPE} ${WORKLOAD_NAME} ${NAMESPACE} ${CONTEXT}
    ...    env={"KUBECONFIG":"./${kubeconfig.key}", "OUTPUT_DIR":"${OUTPUT_DIR}"}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}","WORKLOAD_TYPE":"${WORKLOAD_TYPE}", "WORKLOAD_NAME":"${WORKLOAD_NAME}", "NAMESPACE":"${NAMESPACE}", "CONTEXT":"${CONTEXT}", "OUTPUT_DIR":"${OUTPUT_DIR}"}


Scan And Score Issues
    [Arguments]    ${TASK}    ${SCAN_SCRIPT}    ${ISSUE_FILE}

    ${cli_result}=    RW.CLI.Run Bash File
    ...    bash_file=${SCAN_SCRIPT}
    ...    env=${env}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true  
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=jq '.issues' ${OUTPUT_DIR}/${ISSUE_FILE}
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    ${${TASK}_score}=    Evaluate    1 if len(@{issue_list}) == 0 else 0 
    Set Global Variable    ${${TASK}_score}
