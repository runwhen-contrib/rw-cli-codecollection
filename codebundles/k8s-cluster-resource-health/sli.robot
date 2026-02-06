*** Settings ***
Documentation       Counts the number of nodes above 90% CPU or Memory Utilization from kubectl top. 
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes Cluster Resource Health
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization
*** Tasks ***
Identify High Utilization Nodes for Cluster `${CONTEXT}` 
    [Documentation]    Fetch utilization of each node and raise issue if CPU or Memory is above 90% utilization . Requires jq. Requires get/list of nodes in "metrics.k8s.io" 
    [Tags]        Cluster     Resources    CPU    Memory    Utilization    Saturation    Exhaustion    Starvation
    ${node_usage_details}=    RW.CLI.Run Bash File
    ...    bash_file=get_high_use_nodes.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=False
    ${node_list}=    Evaluate    json.loads(r'''${node_usage_details.stdout}''')    json
    ${metric}=    Evaluate    len(@{node_list})

    ${high_node_usage_score}=    Evaluate    0 if ${metric} > 0 else 1
    Set Global Variable    ${high_node_usage_score}
    RW.Core.Push Metric    ${high_node_usage_score}    sub_name=node_utilization

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

    ${resource_limit_health_score}=    Evaluate    0 if ${events} > 0 else 1
    Set Global Variable    ${resource_limit_health_score}
    RW.Core.Push Metric    ${resource_limit_health_score}    sub_name=resource_limits

Generate Cluster Resource Health Score
    ${cluster_resource_health_score}=      Evaluate  (${resource_limit_health_score} + ${high_node_usage_score} ) / 2
    ${health_score}=      Convert to Number    ${cluster_resource_health_score}  2
    RW.Core.Push Metric    ${health_score}

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

