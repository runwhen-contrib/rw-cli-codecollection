*** Settings ***
Documentation       Detects and analyzes stacktraces/tracebacks in Kubernetes workload logs for troubleshooting application issues.
Metadata            Author    akshayrw25
Metadata            Display Name    Kubernetes Workload Stacktrace Analysis
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.NextSteps
Library             RW.K8sHelper
Library             RW.LogAnalysis.ExtractTraceback
Library             OperatingSystem
Library             String
Library             Collections

Suite Setup         Suite Initialization


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    pattern=\w*
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=The name of the Kubernetes namespace to scope actions and searching to.
    ...    pattern=\w*
    ...    example=otel-demo
    ${WORKLOAD_NAME}=    RW.Core.Import User Variable    WORKLOAD_NAME
    ...    type=string
    ...    description=The name of the workload (deployment, statefulset, or daemonset) to analyze for stacktraces.
    ...    pattern=\w*
    ...    example=otel-demo-frontend
    ${WORKLOAD_TYPE}=    RW.Core.Import User Variable    WORKLOAD_TYPE
    ...    type=string
    ...    description=The type of Kubernetes workload to analyze.
    ...    pattern=\w*
    ...    enum=[deployment,statefulset,daemonset]
    ...    example=deployment
    ...    default=deployment
    ${LOG_LINES}=    RW.Core.Import User Variable    LOG_LINES
    ...    type=string
    ...    description=The number of log lines to fetch from the pods when inspecting logs.
    ...    pattern=\d+
    ...    example=100
    ...    default=5000
    ${LOG_AGE}=    RW.Core.Import User Variable    LOG_AGE
    ...    type=string
    ...    description=The age of logs to fetch from pods, used for log analysis tasks.
    ...    pattern=\w*
    ...    example=1h
    ...    default=15m
    ${LOG_SIZE}=    RW.Core.Import User Variable    LOG_SIZE
    ...    type=string
    ...    description=The maximum size of logs in bytes to fetch from pods, used for log analysis tasks. Defaults to 2MB.
    ...    pattern=\d*
    ...    example=1024
    ...    default=2097152
    ${IGNORE_CONTAINERS_MATCHING}=    RW.Core.Import User Variable    IGNORE_CONTAINERS_MATCHING
    ...    type=string
    ...    description=comma-separated string of keywords used to identify and skip container names containing any of these substrings."
    ...    pattern=\w*
    ...    example=linkerd,initX
    ...    default=linkerd
    
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}
    Set Suite Variable    ${WORKLOAD_NAME}
    Set Suite Variable    ${WORKLOAD_TYPE}
    Set Suite Variable    ${LOG_LINES}
    Set Suite Variable    ${LOG_AGE}
    Set Suite Variable    ${LOG_SIZE}
    Set Suite Variable    ${IGNORE_CONTAINERS_MATCHING}
    
    # Construct environment dictionary safely to handle special characters in regex patterns
    &{env_dict}=    Create Dictionary    
    ...    KUBECONFIG=${kubeconfig.key}
    ...    KUBERNETES_DISTRIBUTION_BINARY=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    CONTEXT=${CONTEXT}
    ...    NAMESPACE=${NAMESPACE}
    ...    WORKLOAD_NAME=${WORKLOAD_NAME}
    ...    WORKLOAD_TYPE=${WORKLOAD_TYPE}
    Set Suite Variable    ${env}    ${env_dict}
    
    # Check if deployment is scaled to 0 and handle appropriately
    ${scale_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get ${WORKLOAD_TYPE}/${WORKLOAD_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '{spec_replicas: .spec.replicas, ready_replicas: (.status.readyReplicas // 0), available_condition: (.status.conditions[] | select(.type == "Available") | .status // "Unknown")}'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=30
    
    TRY
        ${scale_status}=    Evaluate    json.loads(r'''${scale_check.stdout}''') if r'''${scale_check.stdout}'''.strip() else {}    json
        ${spec_replicas}=    Evaluate    $scale_status.get('spec_replicas', 1)
        
        # DaemonSets don't scale to 0 in the traditional sense, so skip scale-down logic for them
        IF    '${WORKLOAD_TYPE}' == 'daemonset'
            Log    ${WORKLOAD_TYPE} ${WORKLOAD_NAME} is a DaemonSet - proceeding with stacktrace analysis
            Set Suite Variable    ${SKIP_STACKTRACE_CHECKS}    ${False}
        ELSE IF    ${spec_replicas} == 0
            RW.Core.Add Issue
            ...    severity=4
            ...    expected=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` operational status documented
            ...    actual=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` is intentionally scaled to zero replicas
            ...    title=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` is Scaled Down (Informational)
            ...    reproduce_hint=kubectl get ${WORKLOAD_TYPE}/${WORKLOAD_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o yaml
            ...    details=${WORKLOAD_TYPE} `${WORKLOAD_NAME}` is currently scaled to 0 replicas (spec.replicas=0). This is an intentional configuration and not an error. All pod-related healthchecks have been skipped for efficiency. If the workload should be running, scale it up using:\nkubectl scale ${WORKLOAD_TYPE}/${WORKLOAD_NAME} --replicas=<desired_count> --context ${CONTEXT} -n ${NAMESPACE}
            ...    next_steps=This is informational only. If the workload should be running, scale it up.
            
            RW.Core.Add Pre To Report    **ℹ️ ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` is scaled to 0 replicas - Skipping stacktrace analysis**\n**Available Condition:** ${scale_status.get('available_condition', 'Unknown')}
            
            Set Suite Variable    ${SKIP_STACKTRACE_CHECKS}    ${True}
        ELSE
            Set Suite Variable    ${SKIP_STACKTRACE_CHECKS}    ${False}
        END
        
    EXCEPT
        Log    Warning: Failed to check workload scale, continuing with normal checks
        Set Suite Variable    ${SKIP_STACKTRACE_CHECKS}    ${False}
    END


*** Tasks ***
Analyze Workload Stacktraces for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` in Namespace `${NAMESPACE}`
    [Documentation]    Collects and analyzes stacktraces/tracebacks from all pods in the workload for troubleshooting application issues.
    [Tags]
    ...    logs
    ...    stacktraces
    ...    tracebacks
    ...    workload
    ...    troubleshooting
    ...    errors
    ...    access:read-only
    # Skip pod-related checks if deployment is scaled to 0
    IF    not ${SKIP_STACKTRACE_CHECKS}

        # Step-1: Fetch all pods for the workload
        ${workload_pod_names_lines}=    RW.CLI.Run Cli
        ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context ${CONTEXT} -n ${NAMESPACE} -l app=${WORKLOAD_NAME} -o name
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        ...    show_in_rwl_cheatsheet=true
        ...    render_in_commandlist=true
        
        IF    ${workload_pod_names_lines.returncode} == 0
            # split lines to get the pods as a list of pod-names
            ${workload_pod_names_list}=    Split To Lines    ${workload_pod_names_lines.stdout}
            
            # Step-2: iterate through each pod-name and fetch its logs
            FOR    ${pod_name}    IN    @{workload_pod_names_list}
                # Step-3: Fetch container names of this pod
                ${pod_container_names_lines}=    RW.CLI.Run Cli
                ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get ${pod_name} --context ${CONTEXT} -n ${NAMESPACE} -o jsonpath='{range .spec.containers[*]}{.name}{"\\n"}{end}'
                ...    env=${env}
                ...    secret_file__kubeconfig=${kubeconfig}
                ...    show_in_rwl_cheatsheet=true
                ...    render_in_commandlist=true
                
                IF    ${pod_container_names_lines.returncode} == 0
                    # split lines to get the list of container names 
                    ${container_names_list}=    Split To Lines    ${pod_container_names_lines.stdout}
                    
                    # separate the csv argument into a list of patterns to ignore.
                    ${ignore_container_patterns}=    Split String    ${IGNORE_CONTAINERS_MATCHING}    ,
        
                    # Step-4: iterate through each container within each pod and fetch its logs
                    FOR    ${container_name}    IN    @{container_names_list}
                        
                        # skip log-fetch for this container if its name is to be ignored
                        ${skip_container}=    Set Variable    ${False}
                        
                        TRY                            
                            # try matching patterns to the container name to determine if its to be ignored
                            FOR    ${filter}    IN    @{ignore_container_patterns}
                                IF    '${filter}' in '${container_name}'
                                    ${skip_container}=    Set Variable    ${True}
                                    Exit For Loop
                                END
                            END

                            IF    not ${skip_container}
                                # Step-5: Fetch raw logs for this pod.container
                                ${workload_logs}=    RW.CLI.Run Cli
                                ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} logs ${pod_name} --context ${CONTEXT} -n ${NAMESPACE} -c ${container_name} --tail=${LOG_LINES} --since=${LOG_AGE} --limit-bytes ${LOG_SIZE}
                                ...    env=${env}
                                ...    secret_file__kubeconfig=${kubeconfig}
                                ...    show_in_rwl_cheatsheet=true
                                ...    render_in_commandlist=true
                                
                                IF    ${workload_logs.returncode} != 0
                                    RW.Core.Add Issue
                                    ...    severity=3
                                    ...    expected=Workload logs should be accessible for stacktrace analysis for POD `${pod_name}` in namespace `${NAMESPACE}`
                                    ...    actual=Failed to fetch workload logs for stacktrace analysis for POD `${pod_name}` in namespace `${NAMESPACE}`
                                    ...    title=Unable to Fetch Workload Logs for Stacktrace Analysis `${WORKLOAD_NAME}`
                                    ...    reproduce_hint=${workload_logs.cmd}
                                    ...    details=Log collection failed with exit code ${workload_logs.returncode}:\n\nSTDOUT:\n${workload_logs.stdout}\n\nSTDERR:\n${workload_logs.stderr}
                                    ...    next_steps=Verify kubeconfig is valid and accessible\nCheck if context '${CONTEXT}' exists and is reachable\nVerify namespace '${NAMESPACE}' exists\nConfirm ${WORKLOAD_TYPE} '${WORKLOAD_NAME}' exists in the namespace\nCheck if pod '${pod_name}' exists and is reachable\n
                                ELSE
                                    ${tracebacks}=    RW.LogAnalysis.ExtractTraceback.Extract Tracebacks
                                    ...    logs=${workload_logs.stdout}
                                    
                                    # check total no. of tracebacks extracted
                                    ${total_tracebacks}=    Get Length     ${tracebacks}

                                    IF    ${total_tracebacks} == 0
                                        # no tracebacks found for this container in this pod
                                        RW.Core.Add Pre To Report    **📋 No Stacktraces for Container `${container_name}` in Pod `${pod_name}` for ${WORKLOAD_TYPE} ${WORKLOAD_NAME} Found in Last ${LOG_LINES} lines, ${LOG_AGE} age.**\n**Commands Used:** ${workload_logs.cmd}\n\n
                                    ELSE
                                        ${agg_tracebacks}=    Evaluate    "-----------------------------------------------------------\\n".join(${tracebacks})
                                        RW.Core.Add Pre To Report    **🔍 Stacktraces Found for Container `${container_name}` in Pod `${pod_name}` for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}`:**\n\n${agg_tracebacks}\n\n

                                        RW.Core.Add Issue
                                        ...    severity=2
                                        ...    expected=No Stacktraces for Container `${container_name}` in Pod `${pod_name}` for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` Found.
                                        ...    actual=Stacktraces are found for Container `${container_name}` in Pod `${pod_name}` for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}`
                                        ...    title=Stacktraces detected in Container `${container_name}` for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}`
                                        ...    reproduce_hint=${workload_logs.cmd}
                                        ...    details=${tracebacks}
                                        ...    next_steps=Inspect container `${container_name}` inside pod `${pod_name}` managed by ${WORKLOAD_TYPE} `${WORKLOAD_NAME}`\nReview application logs for the root cause of the stacktrace\nCheck application configuration and resource limits\nConsider scaling or restarting the ${WORKLOAD_TYPE} if issues persist
                                        ...    next_action=analyseStacktrace
                                    END
                                END
                            END                
                        EXCEPT    AS    ${error}
                            RW.Core.Add Pre To Report    Exception encountered for container `${container_name}` in pod `${pod_name}` for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}`\n:${error}
                        END
                    END            
                ELSE
                    RW.Core.Add Issue
                    ...    severity=3
                    ...    expected=Container list should be retrievable for pod `${pod_name}` in ${WORKLOAD_TYPE} `${WORKLOAD_NAME}`
                    ...    actual=Failed to retrieve container list for pod `${pod_name}` in ${WORKLOAD_TYPE} `${WORKLOAD_NAME}`
                    ...    title=Unable to List Containers in ${WORKLOAD_TYPE} `${WORKLOAD_NAME}`
                    ...    reproduce_hint=${pod_container_names_lines.cmd}
                    ...    details=Container listing failed with return code: ${pod_container_names_lines.returncode}, stderr: ${pod_container_names_lines.stderr}
                    ...    next_steps=Verify pod exists and is accessible\nCheck kubeconfig and context configuration\nEnsure proper RBAC permissions for pod inspection
                END
            END
        ELSE
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=Pod list should be retrievable for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` in namespace `${NAMESPACE}`
            ...    actual=Failed to retrieve pod list for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` in namespace `${NAMESPACE}`
            ...    title=Unable to List Pods for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}`
            ...    reproduce_hint=${workload_pod_names_lines.cmd}
            ...    details=Pod listing failed with return code: ${workload_pod_names_lines.returncode}, stderr: ${workload_pod_names_lines.stderr}
            ...    next_steps=Verify ${WORKLOAD_TYPE} exists in the specified namespace\nCheck kubeconfig and context configuration\nEnsure proper RBAC permissions for pod listing\nConfirm namespace '${NAMESPACE}' exists
        END
    END
