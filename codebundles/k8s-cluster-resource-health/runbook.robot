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

Suite Setup         Suite Initialization


*** Tasks ***
Identify High Utilization Nodes for Cluster `${CONTEXT}`
    [Documentation]    Identify nodes with high utilization . Requires jq.
    [Tags]    cluster    resources    cpu    memory    utilization    saturation    exhaustion    starvation
    ${node_usage_details}=    RW.CLI.Run Bash File
    ...    bash_file=get_high_use_nodes.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=False
    ...    show_in_rwl_cheatsheet=true
    ${node_list}=    Evaluate    json.loads(r'''${node_usage_details.stdout}''')    json
    IF    len(@{node_list}) > 0
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Nodes in Cluster Context `${CONTEXT}` should have available CPU and Memory resources.
        ...    actual=Nodes in Cluster Context `${CONTEXT}` should have available CPU and Memory resources.
        ...    title= Node usage is too high in Cluster Context `${CONTEXT}`.
        ...    reproduce_hint=View Commands Used in Report Output
        ...    details=Node CPU and Memory Utilization: ${node_list}
        ...    next_steps=Identify Pods Causing High Node Utilization in Cluster `${CONTEXT}` \nAdd Nodes to Cluster Context `${CONTEXT}` 
    END
    RW.Core.Add Pre To Report    Node Usage Details:\n${node_usage_details.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${node_usage_details.cmd}

Identify Pods Causing High Node Utilization in Cluster `${CONTEXT}`
    [Documentation]    Identify nodes with high utilization and match to pods that are significantly above their resource request configuration. Requires jq.
    [Tags]    pods    resources    requests    utilization    cpu    memory    exhaustion
    ${pod_and_node_usage_details}=    RW.CLI.Run Bash File
    ...    bash_file=pods_impacting_high_use_nodes.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=False
    ...    show_in_rwl_cheatsheet=true
    
    ${namespace_list}=    Evaluate    json.loads(r'''${pod_and_node_usage_details.stdout}''')    json

    IF    len(@{namespace_list}) > 0
        FOR    ${item}    IN    @{namespace_list}
            ${pod_details}=    Get From Dictionary    ${namespace_list}    ${item}
            RW.Core.Add Issue
            ...    severity=2
            ...    expected=Pods in Cluster Context `${CONTEXT}` are causing resource pressure.
            ...    actual=Pods in Cluster Context `${CONTEXT}` should have appropriate resource requests that do not cause pressure.
            ...    title= Pods in namespace `${item}` are contributing to resource pressure in Cluster Context `${CONTEXT}`.
            ...    reproduce_hint=View Commands Used in Report Output
            ...    details=Node CPU and Memory Utilization: ${pod_details}
            ...    next_steps=Add Nodes to Cluster Context `${CONTEXT}` \nIncrease Pod Resource Requests \nIdentify Pod Resource Recommendations in Namespace `${item}`
        END
    END

    RW.Core.Add Pre To Report    Pods Needing Adjustment:\n${pod_and_node_usage_details.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${pod_and_node_usage_details.cmd}


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
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
