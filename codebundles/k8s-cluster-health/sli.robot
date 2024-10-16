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
Check for Node Restarts in Cluster `${CONTEXT}`
    [Documentation]    Count preempt / spot node restarts within the configured time interval.
    [Tags]    cluster    preempt    spot    node    restart
    ${node_usage_details}=    RW.CLI.Run Bash File
    ...    bash_file=node_restart_check.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=False
    ${node_list}=    Evaluate    json.loads(r'''${node_usage_details.stdout}''')    json
    ${metric}=    Evaluate    len(@{node_list})

    RW.Core.Add Pre To Report    Commands Used:\n${node_usage_details.cmd}
    RW.Core.Add Pre To Report    Nodes with High Utilization:\n${node_usage_details.stdout}

    RW.Core.Push Metric    ${metric}


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
