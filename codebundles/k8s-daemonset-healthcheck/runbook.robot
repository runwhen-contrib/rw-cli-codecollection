*** Settings ***
Metadata          Author    Jonathan Funk
Documentation     Triages issues related to a Daemonset and its available replicas.
Suite Setup       Suite Initialization
Library           BuiltIn
Library           RW.Core
Library           RW.CLI
Library           RW.platform
Library           OperatingSystem

*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    ...    example=For examples, start here https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
    ${kubectl}=    RW.Core.Import Service    kubectl
    ...    description=The location service used to interpret shell commands.
    ...    default=kubectl-service.shared
    ...    example=kubectl-service.shared
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
    ${LABELS}=    RW.Core.Import User Variable    LABELS
    ...    type=string
    ...    description=A Kubernetes label selector string used to filter/find relevant resources for troubleshooting.
    ...    pattern=\w*
    ...    example=Could not render example.
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${DAEMONSET_NAME}    ${DAEMONSET_NAME}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
    IF    "${LABELS}" != ""
        ${LABELS}=    Set Variable    -l ${LABELS}        
    END
    Set Suite Variable    ${LABELS}    ${LABELS}

*** Tasks ***
Fetch Daemonset Logs
    [Documentation]    Fetches the last 100 lines of logs for the given daemonset in the namespace.
    [Tags]    Fetch    Log    Pod    Container    Errors    Inspect    Trace    Info    Daemonset    csi
    ${logs}=    RW.CLI.Run Cli
    ...    cmd=kubectl logs --tail=100 daemonset/${DAEMONSET_NAME} --context ${CONTEXT} -n ${NAMESPACE}
    ...    env=${env}
    ...    target_service=${kubectl}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${logs.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Get Related Daemonset Events
    [Documentation]    Fetches events related to the daemonset workload in the namespace.
    [Tags]    Events    Workloads    Errors    Warnings    Get    Daemonset    csi
    ${events}=    RW.CLI.Run Cli
    ...    cmd=kubectl get events --field-selector type=Warning --context ${CONTEXT} -n ${NAMESPACE} | grep -i "${DAEMONSET_NAME}"
    ...    env=${env}
    ...    target_service=${kubectl}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${events.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check Daemonset Replicas
    [Documentation]    Pulls the replica information for a given daemonset and checks if it's highly available
    ...                , if the replica counts are the expected / healthy values, and if not, what they should be.
    [Tags]    Daemonset    csi    Replicas    Desired    Actual    Available    Ready    Unhealthy    Rollout    Stuck    Pods
    ${daemonset_describe}=    RW.CLI.Run Cli
    ...    cmd=kubectl describe daemonset/${DAEMONSET_NAME} --context ${CONTEXT} -n ${NAMESPACE}
    ...    env=${env}
    ...    target_service=${kubectl}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${daemonset}=    RW.CLI.Run Cli
    ...    cmd=kubectl get daemonset/${DAEMONSET_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json
    ...    env=${env}
    ...    target_service=${kubectl}
    ...    secret_file__kubeconfig=${kubeconfig}
    # status fields
    ${current_scheduled}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${daemonset}
    ...    extract_path_to_var__current_scheduled=status.currentNumberScheduled || `0`
    ...    current_scheduled__raise_issue_if_lt=1
    ...    assign_stdout_from_var=current_scheduled
    ${desired_scheduled}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${daemonset}
    ...    extract_path_to_var__desired_scheduled=status.desiredNumberScheduled || `0`
    ...    desired_scheduled__raise_issue_if_lt=1
    ...    assign_stdout_from_var=desired_scheduled
    ${available}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${daemonset}
    ...    extract_path_to_var__available=status.numberAvailable || `0`
    ...    available__raise_issue_if_lt=1
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
    ...    assign_stdout_from_var=ready
    ${unavailable}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${daemonset}
    ...    extract_path_to_var__unavailable=status.numberUnavailable || `0`
    ...    unavailable__raise_issue_if_gt=0
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
    RW.CLI.Parse Cli Json Output
    ...    rsp=${current_scheduled}
    ...    extract_path_to_var__comparison=@
    ...    comparison__raise_issue_if_neq=${available}
    RW.Core.Add Pre To Report    Deployment State:\n${daemonset_describe.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}