*** Settings ***
Documentation       Inspects the resources provisioned for a given set of pods and raises issues or recommendations as necessary.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Pod Resources Health
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             String
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Show Pods Without Resource Limit or Resource Requests Set in Namespace `${NAMESPACE}`
    [Documentation]    Scans a list of pods in a namespace using labels as a selector and checks if their resources are set.
    [Tags]
    ...    pods
    ...    resources
    ...    resource
    ...    allocation
    ...    cpu
    ...    memory
    ...    startup
    ...    initialization
    ...    prehook
    ...    liveness
    ...    readiness
    ...    ${NAMESPACE}
    ...    access:read-only  
    ${pods_without_limits}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} ${LABELS} --field-selector=status.phase=Running -ojson | jq -r '[.items[] as $pod | ($pod.spec.containers // [][])[] | select(.resources.limits == null) | {pod: $pod.metadata.name, container_without_limits: .name}]'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${no_limits_count}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${pods_without_limits}
    ...    extract_path_to_var__no_limits_count=length(@)
    ...    set_severity_level=4
    ...    no_limit_count__raise_issue_if_gt=0
    ...    set_issue_title=Pods With No Limits In Namespace ${NAMESPACE}
    ...    set_issue_details=Pods found without limits applied in namespace ${NAMESPACE}. \n $_stdout \n Review each manifest and edit configuration to set appropriate resource limits.
    ...    assign_stdout_from_var=no_limits_count
    ...    set_issue_next_steps=Review issue details and set resource limits for pods. 
    ${pods_without_requests}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} ${LABELS} --field-selector=status.phase=Running -ojson | jq -r '[.items[] as $pod | ($pod.spec.containers // [][])[] | select(.resources.requests == null) | {pod: $pod.metadata.name, container_without_requests: .name}]'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${no_requests_count}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${pods_without_requests}
    ...    extract_path_to_var__no_requests_count=length(@)
    ...    set_issue_title=Found pod without resource requests specified in namespace ${NAMESPACE}
    ...    set_severity_level=4
    ...    no_requests_count__raise_issue_if_gt=0
    ...    set_issue_details=Pods found without resource requests applied in namespace ${NAMESPACE}. \n $_stdout \n Review each manifest and edit configuration to set appropriate resource limits.
    ...    assign_stdout_from_var=no_requests_count
    ...    set_issue_next_steps=Review issue details and set resource requests for pods. 
    ${history}=    RW.CLI.Pop Shell History
    ${no_requests_pod_count}=    Convert To Number    ${no_requests_count.stdout}
    ${no_limits_pod_count}=    Convert To Number    ${no_limits_count.stdout}
    ${container_count}=    Set Variable    ${no_requests_pod_count} + ${no_limits_pod_count}
    ${summary}=    Set Variable    No containers with unset resources found!
    IF    ${container_count} > 0
        ${summary}=    Set Variable
        ...    ${container_count} containers found without resources specified:\n${pods_without_limits.stdout}\n ${pods_without_requests.stdout}
    END
    RW.Core.Add Pre To Report    ${summary}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Check Pod Resource Utilization with Top in Namespace `${NAMESPACE}`
    [Documentation]    Performs and a top command on list of labeled workloads to check pod resources.
    [Tags]     access:read-only  top    resources    utilization    pods    workloads    cpu    memory    allocation    labeled    ${NAMESPACE}
    ${pods_top}=    RW.CLI.Run Cli
    ...    cmd=for pod in $(${KUBERNETES_DISTRIBUTION_BINARY} get pods ${LABELS} -n ${NAMESPACE} --context ${CONTEXT} -o custom-columns=":metadata.name" --field-selector=status.phase=Running); do ${KUBERNETES_DISTRIBUTION_BINARY} top pod $pod -n ${NAMESPACE} --context ${CONTEXT} --containers; done
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${resource_util_info}=    Set Variable    No resource utilization information could be found!
    IF    """${pods_top.stdout}""" != ""
        ${resource_util_info}=    Set Variable    ${pods_top.stdout}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Pod Resources:\n${resource_util_info}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Identify VPA Pod Resource Recommendations in Namespace `${NAMESPACE}`
    [Documentation]    Queries the namespace for any Vertical Pod Autoscaler resource recommendations. 
    [Tags]     access:read-only  recommendation    resources    utilization    pods    cpu    memory    allocation   vpa    ${NAMESPACE}
    ${vpa_usage}=    RW.CLI.Run Bash File
    ...    bash_file=vpa_recommendations.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    render_in_commandlist=true
    ${recommendations}=    RW.CLI.Run Cli
    ...    cmd=echo '${vpa_usage.stdout}' | awk '/Recommended Next Steps:/ {flag=1; next} flag'
    ...    env=${env}
    ...    include_in_history=false
    ${recommendation_list}=    Evaluate    json.loads(r'''${recommendations.stdout}''')    json
    IF    len(@{recommendation_list}) > 0
        FOR    ${item}    IN    @{recommendation_list}
            RW.Core.Add Issue
            ...    severity=${item["severity"]}
            ...    expected=Resource requests should closely match VPA recommendations.
            ...    actual=Resource requests are not aligned with VPA recommendations. 
            ...    title=Resource requests for container `${item["container"]}` in ${item["object_type"]} `${item["object_name"]}` should be adjusted in namespace `${NAMESPACE}`
            ...    reproduce_hint=kubectl describe vpa ${item["vpa_name"]} -n ${NAMESPACE}
            ...    details=${item}
            ...    next_steps=${item["next_step"]}
        END
    END
    RW.Core.Add Pre To Report    ${vpa_usage.stdout}\n

Identify Overutilized Pods in Namespace `${NAMESPACE}`
    [Documentation]    Scans the namespace for pods that are over utilizing resources or may be experiencing resource problems like oomkills or restarts.
    [Tags]     access:read-only  overutilized    resources    utilization    pods    cpu    memory    allocation    ${NAMESPACE}    oomkill    restarts
    ${pod_usage_analysis}=    RW.CLI.Run Bash File    identify_resource_contrained_pods.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    ${pod_usage_analysis.stdout}
    ${overutilized_pods}=    RW.CLI.Run Cli
    ...    cmd=cat overutilized_pods.json | jq .
    ...    env=${env}
    ${overutilized_pods_list}=    Evaluate
    ...    json.loads(r'''${overutilized_pods.stdout}''')
    ...    json
    FOR    ${item}    IN    @{overutilized_pods_list}
        ${item_owner}=    RW.CLI.Run Bash File
        ...    bash_file=find_resource_owners.sh
        ...    cmd_override=./find_resource_owners.sh Pod ${item["pod"]} ${NAMESPACE} ${CONTEXT}
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        ...    include_in_history=False
        ${item_owner_output}=    RW.CLI.Run Cli
        ...    cmd=echo "${item_owner.stdout}" | sed 's/ *$//' | tr -d '\n'
        ...    env=${env}
        ...    include_in_history=False
        IF    len($item_owner_output.stdout) > 0 and ($item_owner_output.stdout) != "No resource found"
            ${owner_kind}    ${owner_name}=    Split String    ${item_owner_output.stdout}    ${SPACE}
            ${owner_name}=    Replace String    ${owner_name}    \n    ${EMPTY}
        ELSE
            ${owner_kind}=    Set Variable    "Unknown"
            ${owner_name}=    Set Variable    "Unknown"
        END
        IF    'CPU usage exceeds threshold' in $item['reason']
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Pods should be operating under their designated resource limits
            ...    actual=Pods are above their designated resource limits
            ...    title= ${item["reason"]} for pod `${item["pod"]}` in `${item["namespace"]}`
            ...    reproduce_hint=${pod_usage_analysis.cmd}
            ...    details=${item}
            ...    next_steps=Increase CPU limits for ${owner_kind} `${owner_name}` to ${item["recommended_cpu_increase"]} in namespace `${item["namespace"]}`
        END
        IF    'Memory usage exceeds threshold' in $item['reason']
            RW.Core.Add Issue
            ...    severity=3
            ...    expected=Pods should be operating under their designated resource limits
            ...    actual=Pods are above their designated resource limits
            ...    title= ${item["reason"]} for pod `${item["pod"]}` in `${item["namespace"]}`
            ...    reproduce_hint=${pod_usage_analysis.cmd}
            ...    details=${item}
            ...    next_steps=Increase memory limits for ${owner_kind} `${owner_name}` to ${item["recommended_mem_increase"]} in namespace `${item["namespace"]}`\nInvestigate possible memory leaks with ${owner_kind} `${owner_name}`\nAdd or Adjust HorizontalPodAutoScaler or VerticalPodAutoscaler resources to ${owner_kind} `${owner_name}`
        END
        IF    'OOMKilled or exit code 137' in $item['reason']
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=Pods should be operating under their designated resource limits
            ...    actual=Pods are above their designated resource limits
            ...    title= Container restarts detected pod `${item["pod"]}` in `${item["namespace"]}` due to exceeded memory usage
            ...    reproduce_hint=${pod_usage_analysis.cmd}
            ...    details=${item}
            ...    next_steps=Increase memory limits for ${owner_kind} `${owner_name}` to ${item["recommended_mem_increase"]} in namespace `${item["namespace"]}`\nInvestigate possible memory leaks with ${owner_kind} `${owner_name}`\nAdd or Adjust HorizontalPodAutoScaler or VerticalPodAutoscaler resources to ${owner_kind} `${owner_name}`
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
    ${NAMESPACE}=    RW.Core.Import User Variable
    ...    NAMESPACE
    ...    type=string
    ...    description=The name of the Kubernetes namespace to scope actions and searching to. Supports csv list of namespaces.
    ...    pattern=\w*
    ...    example=my-namespace
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
    ...    default=''
    ${LABELS}=    RW.Core.Import User Variable    LABELS
    ...    type=string
    ...    description=The metadata labels to use when selecting the objects to measure as running.
    ...    pattern=\w*
    ...    example=app=myapp
    ...    default=''
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
   ${UTILIZATION_THRESHOLD}=    RW.Core.Import User Variable    UTILIZATION_THRESHOLD
    ...    type=string
    ...    description=The resource usage threshold at which to identify issues. 
    ...    pattern=\d+
    ...    example=95
    ...    default=95
   ${DEFAULT_INCREASE}=    RW.Core.Import User Variable    DEFAULT_INCREASE
    ...    type=string
    ...    description=The percentage increase for resource recommendations.  
    ...    pattern=\d+
    ...    example=25
    ...    default=25
   ${RESTART_AGE}=    RW.Core.Import User Variable    RESTART_AGE
    ...    type=string
    ...    description=The age (in minutes) to consider when looking for container restarts.
    ...    pattern=\d+
    ...    example=10
    ...    default=10
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${DEFAULT_INCREASE}    ${DEFAULT_INCREASE}
    Set Suite Variable    ${UTILIZATION_THRESHOLD}    ${UTILIZATION_THRESHOLD}
    Set Suite Variable    ${RESTART_AGE}    ${RESTART_AGE}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    
    ...    ${env}    
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}","DEFAULT_INCREASE":"${DEFAULT_INCREASE}","UTILIZATION_THRESHOLD":"${UTILIZATION_THRESHOLD}", "RESTART_AGE": "${RESTART_AGE}"}
    IF    "${LABELS}" != ""
        ${LABELS}=    Set Variable    -l ${LABELS}
    END
    Set Suite Variable    ${LABELS}    ${LABELS}
