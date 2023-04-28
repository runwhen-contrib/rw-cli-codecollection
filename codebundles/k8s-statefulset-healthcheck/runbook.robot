*** Settings ***
Metadata          Author    Jonathan Funk
Documentation     Triages issues related to a StatefulSet and its replicas.
Force Tags        K8s    Kubernetes    Kube    K8    Triage    Troubleshoot    StatefulSet    Set    Pods    Replicas
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
    ${STATEFULSET_NAME}=    RW.Core.Import User Variable    STATEFULSET_NAME
    ...    type=string
    ...    description=Used to target the resource for queries and filtering events.
    ...    pattern=\w*
    ...    example=my-database
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
    ...    description=The Kubernetes labels used to fetch the first matching statefulset.
    ...    pattern=\w*
    ...    example=Could not render example.
    ...    default=
    ${BINARY_USED}=    RW.Core.Import User Variable    BINARY_USED
    ...    type=string
    ...    description=Which binary to use for CLI commands
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${BINARY_USED}    ${BINARY_USED}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${STATEFULSET_NAME}    ${STATEFULSET_NAME}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
    IF    "${LABELS}" != ""
        ${LABELS}=    Set Variable    -l ${LABELS}        
    END
    Set Suite Variable    ${LABELS}    ${LABELS}


*** Tasks ***
Fetch StatefulSet Logs
    [Documentation]    Fetches the last 100 lines of logs for the given statefulset in the namespace.
    [Tags]    Fetch    Log    Pod    Container    Errors    Inspect    Trace    Info    StatefulSet
    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${BINARY_USED} logs --tail=100 statefulset/${STATEFULSET_NAME} --context ${CONTEXT} -n ${NAMESPACE}
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${logs.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Get Related StatefulSet Events
    [Documentation]    Fetches events related to the StatefulSet workload in the namespace.
    [Tags]    Events    Workloads    Errors    Warnings    Get    StatefulSet
    ${events}=    RW.CLI.Run Cli
    ...    cmd=${BINARY_USED} get events --context ${CONTEXT} -n ${NAMESPACE} | grep -i "${STATEFULSET_NAME}"
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${events.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Fetch StatefulSet Manifest Details
    [Documentation]    Fetches the current state of the statefulset manifest for inspection.
    [Tags]    StatefulSet    Details    Manifest    Info
    ${statefulset}=    RW.CLI.Run Cli
    ...    cmd=${BINARY_USED} get statefulset ${LABELS} --context=${CONTEXT} -n ${NAMESPACE} -o yaml
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${statefulset.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check StatefulSet Replicas
    [Documentation]    Pulls the replica information for a given StatefulSet and checks if it's highly available
    ...                , if the replica counts are the expected / healthy values, and if not, what they should be.
    [Tags]    StatefulSet    Replicas    Desired    Actual    Available    Ready    Unhealthy    Rollout    Stuck    Pods
    ${statefulset}=    RW.CLI.Run Cli
    ...    cmd=${BINARY_USED} get statefulset ${LABELS} --context=${CONTEXT} -n ${NAMESPACE} -o=jsonpath='{.items[0]}'
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${available_replicas}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${statefulset}
    ...    extract_path_to_var__available_replicas=status.availableReplicas || `0`
    ...    available_replicas__raise_issue_if_lt=1
    ...    assign_stdout_from_var=available_replicas
    RW.CLI.Parse Cli Json Output
    ...    rsp=${available_replicas}
    ...    extract_path_to_var__available_replicas=@
    ...    available_replicas__raise_issue_if_lt=3
    ${desired_replicas}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${statefulset}
    ...    extract_path_to_var__desired_replicas=status.replicas || `0`
    ...    desired_replicas__raise_issue_if_lt=1
    ...    assign_stdout_from_var=desired_replicas
    RW.CLI.Parse Cli Json Output
    ...    rsp=${desired_replicas}
    ...    extract_path_to_var__desired_replicas=@
    ...    desired_replicas__raise_issue_if_neq=${available_replicas.stdout}
    ${desired_replicas}=    Convert To Number    ${desired_replicas.stdout}
    ${available_replicas}=    Convert To Number    ${available_replicas.stdout}
    RW.Core.Add Pre To Report    StatefulSet State:\n${StatefulSet}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}