*** Settings ***
Documentation       Triages issues related to a Daemonset and its available replicas.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Daemonset Triage
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Get DaemonSet Logs for `${DAEMONSET_NAME}` and Add to Report
    [Documentation]    Fetches the last 100 lines of logs for the given daemonset in the namespace.
    [Tags]    fetch    log    pod    container    errors    inspect    trace    info    daemonset    csi    access:read-only
    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} logs --tail=100 daemonset/${DAEMONSET_NAME} --context ${CONTEXT} -n ${NAMESPACE}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${logs.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Get Related Daemonset `${DAEMONSET_NAME}` Events in Namespace `${NAMESPACE}`
    [Documentation]    Fetches events related to the daemonset workload in the namespace.
    [Tags]    access:read-only  events    workloads    errors    warnings    get    daemonset    csi
    ${events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --field-selector type=Warning --context ${CONTEXT} -n ${NAMESPACE} | grep -i "${DAEMONSET_NAME}" || true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${events.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check Daemonset `${DAEMONSET_NAME}` Replicas
    [Documentation]    Pulls the replica information for a given daemonset and checks if it's highly available
    ...    , if the replica counts are the expected / healthy values, and if not, what they should be.
    [Tags]
    ...    daemonset
    ...    csi
    ...    replicas
    ...    desired
    ...    actual
    ...    available
    ...    ready
    ...    unhealthy
    ...    rollout
    ...    stuck
    ...    pods
    ...    access:read-only
    ${daemonset_describe}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} describe daemonset/${DAEMONSET_NAME} --context ${CONTEXT} -n ${NAMESPACE}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${daemonset}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get daemonset/${DAEMONSET_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    # status fields
    ${current_scheduled}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${daemonset}
    ...    extract_path_to_var__current_scheduled=status.currentNumberScheduled || `0`
    ...    current_scheduled__raise_issue_if_lt=1
    ...    set_issue_title=The daemonset ${DAEMONSET_NAME} Pods Not Scheduled
    ...    set_issue_details=Scheduling issue with daemonset ${DAEMONSET_NAME} pods in ${NAMESPACE} - there are no scheduled pods. Check node health, events, and namespace events.
    ...    assign_stdout_from_var=current_scheduled
    ${desired_scheduled}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${daemonset}
    ...    extract_path_to_var__desired_scheduled=status.desiredNumberScheduled || `0`
    ...    desired_scheduled__raise_issue_if_lt=1
    ...    set_issue_title=Daemonset ${DAEMONSET_NAME} Pods Not Ready
    ...    set_issue_details=No daemonset pods ready under ${DAEMONSET_NAME} in namespace ${NAMESPACE}, check the daemonset events, helm or kustomization objects, and configuration.
    ...    assign_stdout_from_var=desired_scheduled
    ${available}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${daemonset}
    ...    extract_path_to_var__available=status.numberAvailable || `0`
    ...    available__raise_issue_if_lt=1
    ...    set_issue_title=Daemonset ${DAEMONSET_NAME} Pods Not Available
    ...    set_issue_details=Scheduling issue with daemonset pods under ${DAEMONSET_NAME} in namespace ${NAMESPACE} - there are none available. Check node health, events, and namespace events.
    ...    assign_stdout_from_var=available
    ${misscheduled}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${daemonset}
    ...    extract_path_to_var__misscheduled=status.numberMisscheduled || `0`
    ...    misscheduled__raise_issue_if_gt=0
    ...    assign_stdout_from_var=misscheduled
    ${ready}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${daemonset}
    ...    extract_path_to_var__ready=status.numberReady || `0`
    ...    ready__raise_issue_if_lt=1
    ...    set_issue_title=Daemonset ${DAEMONSET_NAME} Pods Not Ready
    ...    set_issue_details=No daemonset pods ready for ${DAEMONSET_NAME} in ${NAMESPACE}, check the daemonset events, helm or kustomization objects, and configuration.
    ...    assign_stdout_from_var=ready
    ${unavailable}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${daemonset}
    ...    extract_path_to_var__unavailable=status.numberUnavailable || `0`
    ...    unavailable__raise_issue_if_gt=0
    ...    set_issue_title=Daemonset ${DAEMONSET_NAME} Has Unavailable Pods
    ...    set_issue_details=There are $unavailable unavailable pods for daemonset ${DAEMONSET_NAME} in namespace ${NAMESPACE}, check node health, events, and namespace events.
    ...    assign_stdout_from_var=unavailable
    # spec fields
    ${max_unavailable}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${daemonset}
    ...    extract_path_to_var__max_unavailable=spec.updateStrategy.rollingUpdate.maxUnavailable || `0`
    ...    assign_stdout_from_var=max_unavailable
    # field comparisons
    ${unavailable}=    Convert To Number    ${unavailable.stdout}
    ${available}=    Convert To Number    ${available.stdout}
    RW.CLI.Parse Cli Json Output
    ...    rsp=${max_unavailable}
    ...    extract_path_to_var__comparison=@
    ...    comparison__raise_issue_if_lt=${unavailable}
    ...    set_issue_title=Daemonset ${DAEMONSET_NAME} Has Too Many Unavailable Pods
    ...    set_issue_details=More unavailable (found ${unavailable}) daemonset pods for ${DAEMONSET_NAME} than configured max_unavailable: $comparison in namespace ${NAMESPACE}, check node health, events, and namespace events. Cluster might be undergoing a scaling event or upgrade.
    RW.CLI.Parse Cli Json Output
    ...    rsp=${current_scheduled}
    ...    extract_path_to_var__comparison=@
    ...    comparison__raise_issue_if_neq=${available}
    ...    set_issue_details=Fewer than desired (we found ${available}) daemonset pods for ${DAEMONSET_NAME} than configured allowed: $comparison in namespace ${NAMESPACE}, check node health, events, and namespace events. Cluster might be undergoing a scaling event or upgrade.
    RW.Core.Add Pre To Report    Deployment State:\n${daemonset_describe.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${DAEMONSET_NAME}=    RW.Core.Import User Variable    DAEMONSET_NAME
    ...    type=string
    ...    description=Used to target the resource for queries and filtering events.
    ...    pattern=\w*
    ...    example=vault-csi-provider
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
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${DAEMONSET_NAME}    ${DAEMONSET_NAME}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
