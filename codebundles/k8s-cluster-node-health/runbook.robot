*** Settings ***
Documentation       Evaluate cluster node health using kubectl
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes Cluster Node Health
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Check for Node Restarts in Cluster `${CONTEXT}`
    [Documentation]    Identify nodes that are starting and stopping within the time interval.
    [Tags]    cluster    preempt    spot    reboot    utilization    saturation    exhaustion    starvation
    ${node_restart_details}=    RW.CLI.Run Bash File
    ...    bash_file=node_restart_check.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=False
    ...    show_in_rwl_cheatsheet=true
    RW.Core.Add Pre To Report    Node Restart Details:\n${node_restart_details.stdout}
    ${node_events}=    RW.CLI.Run CLI
    ...    cmd= grep "Total start/stop events" <<< "${node_restart_details.stdout}"| awk -F ":" '{print $2}'
    ${events}=    Convert To Number    ${node_events.stdout}
    IF    ${events} > 0
       RW.Core.Add Issue
       ...    severity=4
       ...    expected=Nodes in Cluster Context `${CONTEXT}` are not starting/stopping frequently.
       ...    actual=Nodes in Cluster Context `${CONTEXT}` are starting/stopping in the last ${INTERVAL}.
       ...    title= Nodes in Cluster Context `${CONTEXT}` are starting/stopping in the last ${INTERVAL}.
       ...    reproduce_hint=View Commands Used in Report Output
       ...    details=${node_restart_details.stdout}
       ...    next_steps=Escalate the issue to the service owner if this is behaviour unexpected.  
    END


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
    ${INTERVAL}=    RW.Core.Import User Variable    INTERVAL
    ...    type=string
    ...    description=The time interval in which to look back for node events. 
    ...    pattern=\w*
    ...    default=5 minutes
    ...    example=4 hours, 5 minutes, etc. 
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${INTERVAL}    ${INTERVAL}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}", "CONTEXT":"${CONTEXT}", "INTERVAL":"${INTERVAL}"}
