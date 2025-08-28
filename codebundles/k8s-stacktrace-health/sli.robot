*** Settings ***
Metadata          Author    akshayrw25
Documentation     This SLI monitors stacktrace health in kubernetes workload application logs. Produces a value between 0 (stacktraces detected) and 1 (no stacktraces found). Focuses specifically on application error detection through stacktrace analysis.
Metadata          Display Name    Kubernetes Workload Stacktrace Health SLI
Metadata          Supports    Kubernetes,AKS,EKS,GKE,OpenShift
Suite Setup       Suite Initialization
Library           BuiltIn
Library           RW.Core
Library           RW.CLI
Library           RW.platform
Library           RW.LogAnalysis.ExtractTraceback
Library           OperatingSystem
Library           String
Library           Collections

*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=The name of the Kubernetes namespace to scope actions and searching to.
    ...    pattern=\w*
    ...    example=my-namespace
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
    ${WORKLOAD_NAME}=    RW.Core.Import User Variable    WORKLOAD_NAME
    ...    type=string
    ...    description=The name of the Kubernetes workload to check for stacktraces.
    ...    pattern=\w*
    ...    example=my-workload
    ${WORKLOAD_TYPE}=    RW.Core.Import User Variable    WORKLOAD_TYPE
    ...    type=string
    ...    description=The type of Kubernetes workload to check.
    ...    pattern=\w*
    ...    enum=[deployment,statefulset,daemonset]
    ...    example=deployment
    ...    default=deployment
    ${LOG_AGE}=    RW.Core.Import User Variable    LOG_AGE
    ...    type=string
    ...    description=The time window to fetch logs for stacktrace analysis.
    ...    pattern=((\d+?)m|(\d+?)h)?
    ...    example=10m
    ...    default=10m
    ${MAX_LOG_LINES}=    RW.Core.Import User Variable    MAX_LOG_LINES
    ...    type=string
    ...    description=Maximum number of log lines to fetch per container to prevent API overload.
    ...    pattern=^\d+$
    ...    example=100
    ...    default=100
    ${MAX_LOG_BYTES}=    RW.Core.Import User Variable    MAX_LOG_BYTES
    ...    type=string
    ...    description=Maximum log size in bytes to fetch per container to prevent API overload.
    ...    pattern=^\d+$
    ...    example=256000
    ...    default=256000
    ${IGNORE_CONTAINERS_MATCHING}=    RW.Core.Import User Variable    IGNORE_CONTAINERS_MATCHING
    ...    type=string
    ...    description=comma-separated string of keywords used to identify and skip container names containing any of these substrings."
    ...    pattern=\w*
    ...    example=linkerd,initX
    ...    default=linkerd
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${LOG_AGE}    ${LOG_AGE}
    Set Suite Variable    ${MAX_LOG_LINES}    ${MAX_LOG_LINES}
    Set Suite Variable    ${MAX_LOG_BYTES}    ${MAX_LOG_BYTES}
    Set Suite Variable    ${IGNORE_CONTAINERS_MATCHING}    ${IGNORE_CONTAINERS_MATCHING}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${WORKLOAD_NAME}    ${WORKLOAD_NAME}
    Set Suite Variable    ${WORKLOAD_TYPE}    ${WORKLOAD_TYPE}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
    
    # Initialize score variables
    Set Suite Variable    ${stacktrace_score}    0
    
    # Check if deployment is scaled to 0 and handle appropriately
    ${scale_check}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get ${WORKLOAD_TYPE}/${WORKLOAD_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json | jq '{spec_replicas: .spec.replicas, ready_replicas: (.status.readyReplicas // 0), available_condition: (.status.conditions[] | select(.type == "Available") | .status // "Unknown"), last_scale_time: (.metadata.annotations."deployment.kubernetes.io/last-applied-configuration" // "N/A")}'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=30
    
    TRY
        ${scale_status}=    Evaluate    json.loads(r'''${scale_check.stdout}''') if r'''${scale_check.stdout}'''.strip() else {}    json
        ${spec_replicas}=    Evaluate    $scale_status.get('spec_replicas', 1)
        
        IF    ${spec_replicas} == 0
            Log    ${WORKLOAD_TYPE} ${WORKLOAD_NAME} is scaled to 0 replicas - returning perfect health score
            
            # For scaled-down workloads, return a score of 1.0 to indicate "intentionally down" vs "broken"
            Set Suite Variable    ${SKIP_HEALTH_CHECKS}    ${True}
        ELSE
            Log    ${WORKLOAD_TYPE} ${WORKLOAD_NAME} has ${spec_replicas} desired replicas - proceeding with stacktrace checks
            Set Suite Variable    ${SKIP_HEALTH_CHECKS}    ${False}
        END
        
    EXCEPT
        Log    Warning: Failed to check deployment scale, continuing with normal stacktrace checks
        Set Suite Variable    ${SKIP_HEALTH_CHECKS}    ${False}
    END



*** Tasks ***
Get Stacktrace Health Score for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}`
    [Documentation]    Checks for recent stacktraces/tracebacks related to the workload within a short time window, with filtering to reduce noise.
    [Tags]    stacktraces    tracebacks    errors    recent    fast
    IF    ${SKIP_HEALTH_CHECKS}
        # For scaled-down deployments, return perfect score to indicate "intentionally down" vs "broken"
        ${stacktrace_score}=    Set Variable    1.0
        Set Suite Variable    ${stacktrace_details}     ${WORKLOAD_TYPE} `${WORKLOAD_NAME}` is intentionally scaled to 0 replicas - Score: ${stacktrace_score}
    ELSE
        # default init of stacktrace score
        ${stacktrace_score}=    Set Variable    1.0

        # empty string to store stacktraces/errors-from-commands
        ${stacktrace_details_temp}=    Set Variable    ${EMPTY}

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
            
            # set to True if a stacktrace is found within any valid container of any pod of this workload ==> fire SLI alert
            ${stacktrace_found}=    Set Variable    False

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
                                ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} logs ${pod_name} --context ${CONTEXT} -n ${NAMESPACE} -c ${container_name} --tail=${MAX_LOG_LINES} --since=${LOG_AGE} --limit-bytes ${MAX_LOG_BYTES}
                                ...    env=${env}
                                ...    secret_file__kubeconfig=${kubeconfig}
                                ...    show_in_rwl_cheatsheet=true
                                ...    render_in_commandlist=true
                                
                                IF    ${workload_logs.returncode} == 0                                    
                                    # fetch the recent-most stacktrace
                                    ${recentmost_stacktrace}=    RW.LogAnalysis.ExtractTraceback.Extract Tracebacks
                                    ...    logs=${workload_logs.stdout}
                                    ...    fetch_most_recent=${True}

                                    ${stacktrace_length}=    Get Length    ${recentmost_stacktrace}

                                    IF    ${stacktrace_length} != 0
                                        # stacktrace found                                        
                                        # fast exit out of both loops to fire an alert now that a stacktrace has been found
                                        ${stacktrace_found}=    Set Variable    True
                                        ${stacktrace_score}=    Set Variable    0
                                        ${delimiter}=    Evaluate    '-' * 150
                                        ${stacktrace_details_temp}=    Catenate    ${stacktrace_details_temp}    ${delimiter}\n${recentmost_stacktrace}\n${delimiter}
                                        Exit For Loop
                                    END
                                ELSE
                                    ${stacktrace_details_temp}=    Catenate    ${stacktrace_details_temp}    Unable to fetch workload logs for container `${container_name}` in pod `${pod_name}`
                                END
                            END
                        EXCEPT
                            ${stacktrace_details_temp}=    Catenate    ${stacktrace_details_temp}    Exception encountered for container `${container_name}` in pod `${pod_name}`.
                        END
                    END
                    
                    # fast exit since a stacktrace has been found ==> fire an SLI alert
                    IF    ${stacktrace_found}
                        Exit For Loop
                    END
                ELSE
                    ${stacktrace_details_temp}=    Catenate    ${stacktrace_details_temp}    Error while fetching containers for pod `${pod_name}`
                END
            END
        ELSE
            ${stacktrace_details_temp}=    Catenate    ${stacktrace_details_temp}   Error while fetching pod-names for ${WORKLOAD_TYPE} `${WORKLOAD_NAME}`
        END
        ${stacktrace_details_header}=    Set Variable If    ${stacktrace_found}    **Stacktrace(s) identified**:\n    **No Stacktraces identified.**\n\nHere are the command logs:\n
        Set Suite Variable    ${stacktrace_details}   ${stacktrace_details_header}\n${stacktrace_details_temp}\n\n
    END 

    Set Suite Variable    ${stacktrace_score}
    RW.Core.Push Metric    ${stacktrace_score}

Generate Stacktrace Health Score for `${WORKLOAD_NAME}`
    [Documentation]    Generates the final stacktrace health score and report details
    [Tags]    score    health    stacktraces
    
    IF    ${SKIP_HEALTH_CHECKS}
        # For scaled-down deployments, return perfect score
        ${health_score}=    Set Variable    1.0
        Log    ${WORKLOAD_TYPE} ${WORKLOAD_NAME} is intentionally scaled to 0 replicas - Score: ${health_score}
        RW.Core.Add to Report    Stacktrace Health Score: ${health_score} - ${WORKLOAD_TYPE} intentionally scaled to 0 replicas
    ELSE
        # Use the stacktrace score as the final health score
        ${health_score}=    Set Variable    ${stacktrace_score}
        
        IF    ${stacktrace_score} == 1.0
            RW.Core.Add to Report    Stacktrace Health Score: ${health_score} - No stacktraces detected in workload logs
        ELSE
            RW.Core.Add to Report    Stacktrace Health Score: ${health_score} - Stacktraces detected in workload logs: ${stacktrace_details}
        END
    END
    
    RW.Core.Push Metric    ${health_score}
