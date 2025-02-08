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
    ${errors}=    RW.CLI.Run Bash File
    ...    bash_file=scan_error_logs.sh
    ...    env=${env}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/scan_error_issues.json | jq '{issues: [.issues[] | select(.severity < 4)]}'
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    ${error_log_score}=    Evaluate    1 if len(@{issue_list["issues"]}) == 0 else 0 
    Set Global Variable    ${error_log_score}


Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` for Stack Traces in Namespace `${NAMESPACE}` 
    [Documentation]   Identifies multi-line stack traces from application failures.
    [Tags]    kubernetes    logs    stacktraces    ${WORKLOAD_TYPE}
    ${stacktraces}=    RW.CLI.Run Bash File
    ...    bash_file=scan_stack_traces.sh
    ...    env=${env}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true  
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/scan_stacktrace_issues.json | jq '{issues: [.issues[] | select(.severity < 4)]}'
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    ${stacktrace_log_score}=    Evaluate    1 if len(@{issue_list["issues"]}) == 0 else 0 
    Set Global Variable    ${stacktrace_log_score}

Generate Application Gateway Health Score
    ${log_score}=      Evaluate  (${error_log_score} + ${stacktrace_log_score} ) / 2
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
    ...    bash_file=get_pods_for_workload.sh
    ...    cmd_override=./get_pods_for_workload.sh ${WORKLOAD_TYPE} ${WORKLOAD_NAME} ${NAMESPACE} ${CONTEXT}
    ...    env={"KUBECONFIG":"./${kubeconfig.key}", "OUTPUT_DIR":"${OUTPUT_DIR}"}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}","WORKLOAD_TYPE":"${WORKLOAD_TYPE}", "WORKLOAD_NAME":"${WORKLOAD_NAME}", "NAMESPACE":"${NAMESPACE}", "CONTEXT":"${CONTEXT}", "OUTPUT_DIR":"${OUTPUT_DIR}"}
