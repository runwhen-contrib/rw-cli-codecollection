*** Settings ***
Documentation       Analyzes logs from Kubernetes Application Logs fetched through kubectl
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
    ...    cmd=cat ${OUTPUT_DIR}/scan_error_issues.json | jq '.issues'
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0
        FOR    ${item}    IN    @{issue_list}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` namespace `${NAMESPACE}` has no errors
            ...    actual=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` namespace `${NAMESPACE}` has errors
            ...    reproduce_hint=${errors.cmd}
            ...    details=${item["details"]}        
        END
    END   

Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` for Stack Tracesin Namespace `${NAMESPACE}` 
    [Documentation]   Identifies multi-line stack traces from application failures.
    [Tags]    kubernetes    logs    stacktraces    ${WORKLOAD_TYPE}
    ${stacktraces}=    RW.CLI.Run Bash File
    ...    bash_file=scan_stack_traces.sh
    ...    env=${env}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true  
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/scan_stacktrace_issues.json | jq '.issues'
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0
        FOR    ${item}    IN    @{issue_list}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` namespace `${NAMESPACE}` has no errors
            ...    actual=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` namespace `${NAMESPACE}` has errors
            ...    reproduce_hint=${stacktraces.cmd}
            ...    details=${item["details"]}        
        END
    END   
Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` for Connection Failures in Namespace `${NAMESPACE}`
    [Documentation]   Detects errors related to database, API, or network connectivity issues.
    [Tags]    kubernetes    logs    connection    failure    ${WORKLOAD_TYPE}
    ${conn_failures}=    RW.CLI.Run Bash File
    ...    bash_file=scan_connection_failures.sh
    ...    env=${env}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true 
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/scan_conn_issues.json | jq '.issues'
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0
        FOR    ${item}    IN    @{issue_list}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` namespace `${NAMESPACE}` has no errors
            ...    actual=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` namespace `${NAMESPACE}` has errors
            ...    reproduce_hint=${conn_failures.cmd}
            ...    details=${item["details"]}        
        END
    END   

Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` for Timeout Errors in Namespace `${NAMESPACE}`
    [Documentation]   Checks for application logs indicating request timeouts or slow responses.
    [Tags]    kubernetes    logs    timeout    failure    ${WORKLOAD_TYPE}
    ${timeout_errors}=    RW.CLI.Run Bash File
    ...    bash_file=scan_timeout_errors.sh
    ...    env=${env}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true 
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/scan_timeout_issues.json | jq '.issues'
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0
        FOR    ${item}    IN    @{issue_list}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` namespace `${NAMESPACE}` has no errors
            ...    actual=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` namespace `${NAMESPACE}` has errors
            ...    reproduce_hint=${timeout_errors.cmd}
            ...    details=${item["details"]}        
        END
    END   
Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` for Authentication and Authorization Failures in Namespace `${NAMESPACE}`
    [Documentation]   Identifies issues where applications fail to authenticate or authorize users/services.
    [Tags]    kubernetes    logs    auth    failure    ${WORKLOAD_TYPE}
    ${auth_failures}=    RW.CLI.Run Bash File
    ...    bash_file=scan_auth_failures.sh
    ...    env=${env}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true 
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/scan_auth_issues.json | jq '.issues'
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0
        FOR    ${item}    IN    @{issue_list}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` namespace `${NAMESPACE}` has no errors
            ...    actual=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` namespace `${NAMESPACE}` has errors
            ...    reproduce_hint=${auth_failures.cmd}
            ...    details=${item["details"]}        
        END
    END   
Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` for Null Pointer and Unhandled Exceptions in Namespace `${NAMESPACE}`
    [Documentation]   Finds critical application crashes due to unhandled exceptions in the code.
    [Tags]    kubernetes    logs    exception    ${WORKLOAD_TYPE}
    ${exceptions}=    RW.CLI.Run Bash File
    ...    bash_file=scan_null_pointer_exceptions.sh
    ...    env=${env}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true 
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/scan_exception_issues.json | jq '.issues'
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0
        FOR    ${item}    IN    @{issue_list}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` namespace `${NAMESPACE}` has no errors
            ...    actual=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` namespace `${NAMESPACE}` has errors
            ...    reproduce_hint=${exceptions.cmd}
            ...    details=${item["details"]}        
        END
    END

Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` for Frequent Log Anomalies in Namespace `${NAMESPACE}`
    [Documentation]   Detects repeating log messages that may indicate ongoing issues.
    [Tags]    kubernetes    logs    anomaly    ${WORKLOAD_TYPE}
    ${anomalies}=    RW.CLI.Run Bash File
    ...    bash_file=scan_log_anomalies.sh
    ...    env=${env}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true 
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/scan_anomoly_issues.json | jq '.issues'
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0
        FOR    ${item}    IN    @{issue_list}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` namespace `${NAMESPACE}` has no errors
            ...    actual=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` namespace `${NAMESPACE}` has errors
            ...    reproduce_hint=${anomalies.cmd}
            ...    details=${item["details"]}        
        END
    END

Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` for Application Restarts and Failures in Namespace `${NAMESPACE}`
    [Documentation]   Checks logs for indicators of application restarts outside Kubernetes events.
    [Tags]    kubernetes    logs    restart    ${WORKLOAD_TYPE}
    ${restarts}=    RW.CLI.Run Bash File
    ...    bash_file=scan_application_restarts.sh
    ...    env=${env}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true 
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/scan_application_restarts.json | jq '.issues'
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0
        FOR    ${item}    IN    @{issue_list}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` namespace `${NAMESPACE}` has no errors
            ...    actual=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` namespace `${NAMESPACE}` has errors
            ...    reproduce_hint=${restarts.cmd}
            ...    details=${item["details"]}        
        END
    END   
Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` for Memory and CPU Resource Warnings in Namespace `${NAMESPACE}`
    [Documentation]   Identifies log messages related to high memory or CPU utilization warnings.
    ${resource_issues}=    RW.CLI.Run Bash File
    ...    bash_file=scan_resource_warnings.sh
    ...    env=${env}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/scan_resource_issues.json | jq '.issues'
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0
        FOR    ${item}    IN    @{issue_list}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` namespace `${NAMESPACE}` has no errors
            ...    actual=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` namespace `${NAMESPACE}` has errors
            ...    reproduce_hint=${resource_issues.cmd}
            ...    details=${item["details"]}        
        END
    END
Scan ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` for Service Dependency Failures in Namespace `${NAMESPACE}`
    [Documentation]   Detects failures when the application cannot reach required services (databases, queues, APIs).
    ${dependency_failures}=    RW.CLI.Run Bash File
    ...    bash_file=scan_service_dependency_failures.sh
    ...    env=${env}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
   ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ${OUTPUT_DIR}/scan_service_issues.json | jq '.issues'
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    IF    len(@{issue_list}) > 0
        FOR    ${item}    IN    @{issue_list}
            RW.Core.Add Issue    
            ...    title=${item["title"]}
            ...    severity=${item["severity"]}
            ...    next_steps=${item["next_step"]}
            ...    expected=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` namespace `${NAMESPACE}` has no errors
            ...    actual=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` namespace `${NAMESPACE}` has errors
            ...    reproduce_hint=${dependency_failures.cmd}
            ...    details=${item["details"]}        
        END
    END

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
    ...    cmd_override=get_pods_for_workload.sh ${WORKLOAD_TYPE} ${WORKLOAD_NAME} ${NAMESPACE} ${CONTEXT}
    ...    env={"KUBECONFIG":"./${kubeconfig.key}", "OUTPUT_DIR":"${OUTPUT_DIR}"}
    ...    include_in_history=False
    ...    secret_file__kubeconfig=${kubeconfig}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}","WORKLOAD_TYPE":"${WORKLOAD_TYPE}", "WORKLOAD_NAME":"${WORKLOAD_NAME}", "NAMESPACE":"${NAMESPACE}", "CONTEXT":"${CONTEXT}", "OUTPUT_DIR":"${OUTPUT_DIR}"}
