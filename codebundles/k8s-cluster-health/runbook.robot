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
Check for Node Restarts in Cluster `${CONTEXT}`
    [Documentation]    Identify nodes that are restarting due to a preempt / spot node restart event.
    [Tags]    cluster    preempt    spot    reboot    utilization    saturation    exhaustion    starvation
    ${node_restart_details}=    RW.CLI.Run Bash File
    ...    bash_file=node_restart_check.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=False
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    Node Restart Details:\n${node_restart_details.stdout}

    # ${node_list}=    Evaluate    json.loads(r'''${node_restart_details.stdout}''')    json
    # IF    len(@{node_list}) > 0
    #    RW.Core.Add Issue
    #    ...    severity=2
    #    ...    expected=Nodes in Cluster Context `${CONTEXT}` should have available CPU and Memory resources.
    #    ...    actual=Nodes in Cluster Context `${CONTEXT}` should have available CPU and Memory resources.
    #    ...    title= Node usage is too high in Cluster Context `${CONTEXT}`.
    #    ...    reproduce_hint=View Commands Used in Report Output
    #    ...    details=Node CPU and Memory Utilization: ${node_list}
    #    ...    next_steps=Identify Pods Causing High Node Utilization in Cluster `${CONTEXT}` \nAdd Nodes to Cluster Context `${CONTEXT}`
    # END
    # RW.Core.Add Pre To Report    Node Usage Details:\n${node_usage_details.stdout}
    # RW.Core.Add Pre To Report    Commands Used:\n${node_usage_details.cmd}


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
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}", "CONTEXT":"${CONTEXT}"}
