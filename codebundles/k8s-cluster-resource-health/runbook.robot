*** Settings ***
Documentation       Identify resource constraints or issues in a cluster.
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes Cluster Resource Health
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections
Library             DateTime

Suite Setup         Suite Initialization


*** Tasks ***
Identify High Utilization Nodes for Cluster `${CONTEXT}`
    [Documentation]    Identify nodes with high utilization . Requires jq.
    [Tags]    cluster    resources    cpu    memory    utilization    saturation    exhaustion    starvation    access:read-only
    ${node_usage_details}=    RW.CLI.Run Bash File
    ...    bash_file=get_high_use_nodes.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=False
    ...    show_in_rwl_cheatsheet=true
    ${node_list}=    Evaluate    json.loads(r'''${node_usage_details.stdout}''')    json
    IF    len(@{node_list}) > 0
        ${issue_timestamp}=    DateTime.Get Current Date
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Nodes in Cluster Context `${CONTEXT}` should have available CPU and Memory resources.
        ...    actual=Nodes in Cluster Context `${CONTEXT}` should have available CPU and Memory resources.
        ...    title= Node usage is too high in Cluster Context `${CONTEXT}`.
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Node CPU and Memory Utilization: ${node_list}
        ...    next_steps=Identify Pods Causing High Node Utilization in Cluster `${CONTEXT}` \nAdd Nodes to Cluster Context `${CONTEXT}`
        ...    observed_at=${issue_timestamp}
    END
    RW.Core.Add Pre To Report    Node Usage Details:\n${node_usage_details.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${node_usage_details.cmd}

Identify Pods Causing High Node Utilization in Cluster `${CONTEXT}`
    [Documentation]    Identify nodes with high utilization and match to pods that are significantly above their resource request configuration. Requires jq.
    [Tags]    pods    resources    requests    utilization    cpu    memory    exhaustion    access:read-only
    ${pod_and_node_usage_details}=    RW.CLI.Run Bash File
    ...    bash_file=pods_impacting_high_use_nodes.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=False
    ...    show_in_rwl_cheatsheet=true
    ${pod_list}=    RW.CLI.Run Cli
    ...    cmd=cat pods_exceeding_requests.json 

    ${namespace_list}=    Evaluate    json.loads(r'''${pod_list.stdout}''')    json

    IF    len(@{namespace_list}) > 0
        FOR    ${item}    IN    @{namespace_list}
            ${pod_details}=    Get From Dictionary    ${namespace_list}    ${item}
            ${issue_timestamp}=    DateTime.Get Current Date
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=Pods in Cluster Context `${CONTEXT}` are causing resource pressure.
            ...    actual=Pods in Cluster Context `${CONTEXT}` should have appropriate resource requests that do not cause pressure.
            ...    title= Pods in namespace `${item}` are contributing to resource pressure in Cluster Context `${CONTEXT}`.
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=Node CPU and Memory Utilization: ${pod_details}
            ...    next_steps=Add Nodes to Cluster Context `${CONTEXT}` \nIncrease Pod Resource Requests \nIdentify Pod Resource Recommendations in Namespace `${item}`
            ...    observed_at=${issue_timestamp}
        END
    END

    RW.Core.Add Pre To Report    Pods Needing Adjustment:\n${pod_and_node_usage_details.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${pod_and_node_usage_details.cmd}

Identify Pods with Resource Limits Exceeding Node Capacity in Cluster `${CONTEXT}`
    [Documentation]    Identify any Pods in the Cluster `${CONTEXT}` with resource limits (CPU or Memory) larger than the Node's allocatable capacity.
    [Tags]    nodes    limits    utilization    saturation    exhaustion    access:read-only
    ${overlimit_details}=    RW.CLI.Run Bash File
    ...    bash_file=overlimit_check.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=False
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    Over-limit Pod Details:\n${overlimit_details.stdout}
    ${overlimit_events}=    RW.CLI.Run CLI
    ...    cmd= grep "Total pods flagged" <<< "${overlimit_details.stdout}" | awk -F ":" '{print $2}'
    ${events}=    Convert To Number    ${overlimit_events.stdout}
    IF    ${events} > 0
       ${issue_timestamp}=    DateTime.Get Current Date
       RW.Core.Add Issue
       ...    severity=4
       ...    expected=No pods in Cluster `${CONTEXT}` should exceed the node's allocatable capacity.
       ...    actual=${events} pods in Cluster `${CONTEXT}` have resource limits exceeding node capacity.
       ...    title= Pods in Cluster `${CONTEXT}` exceed node capacity.
       ...    reproduce_hint=View Commands Used in Report Output
       ...    details=${overlimit_details.stdout}
       ...    next_steps=Investigate the listed pods and adjust resource limits accordingly.
       ...    observed_at=${issue_timestamp}
    END
    RW.Core.Add Pre To Report    Total Pods Over Limit:\n${events}

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
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    default=default
    ...    example=my-main-cluster
    ${MAX_LIMIT_PERCENTAGE}=    RW.Core.Import User Variable    MAX_LIMIT_PERCENTAGE
    ...    type=string
    ...    description=The maximum % that a limit can be in regards to the underlying node capacity.
    ...    pattern=\d.
    ...    default=90
    ...    example=90
    Set Suite Variable    ${MAX_LIMIT_PERCENTAGE}    ${MAX_LIMIT_PERCENTAGE}
    ${MEM_USAGE_MIN}=    RW.Core.Import User Variable    MEM_USAGE_MIN
    ...    type=string
    ...    description=The minimum value (in MB) in which to evaluate requests vs usage. Usage below this value are not evaluated. 
    ...    pattern=\d.
    ...    default=100
    ...    example=100
    Set Suite Variable    ${MEM_USAGE_MIN}    ${MEM_USAGE_MIN}
    ${CPU_USAGE_MIN}=    RW.Core.Import User Variable    CPU_USAGE_MIN
    ...    type=string
    ...    description=The minimum value (in millicores) in which to evaluate requests vs usage. Usage below this value are not evaluated. 
    ...    pattern=\d.
    ...    default=100
    ...    example=100
    Set Suite Variable    ${CPU_USAGE_MIN}    ${CPU_USAGE_MIN}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}", "MAX_LIMIT_PERCENTAGE":"${MAX_LIMIT_PERCENTAGE}", "MEM_USAGE_MIN":"${MEM_USAGE_MIN}", "CPU_USAGE_MIN":"${CPU_USAGE_MIN}"}
