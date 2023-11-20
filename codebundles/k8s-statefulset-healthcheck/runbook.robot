*** Settings ***
Documentation       Triages issues related to a StatefulSet and its replicas.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes StatefulSet Triage
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Fetch StatefulSet Logs
    [Documentation]    Fetches the last 100 lines of logs for the given statefulset in the namespace.
    [Tags]    fetch    log    pod    container    errors    inspect    trace    info    statefulset
    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} logs --tail=100 statefulset/${STATEFULSET_NAME} --context ${CONTEXT} -n ${NAMESPACE}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${logs.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Get Related StatefulSet Events
    [Documentation]    Fetches events related to the StatefulSet workload in the namespace.
    [Tags]    events    workloads    errors    warnings    get    statefulset
    ${events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --field-selector type=Warning --context ${CONTEXT} -n ${NAMESPACE} | grep -i "${STATEFULSET_NAME}" || true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${events.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Fetch StatefulSet Manifest Details
    [Documentation]    Fetches the current state of the statefulset manifest for inspection.
    [Tags]    statefulset    details    manifest    info
    ${statefulset}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get statefulset ${LABELS} --context=${CONTEXT} -n ${NAMESPACE} -o yaml
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${statefulset.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

List StatefulSets with Unhealthy Replica Counts
    [Documentation]    Pulls the replica information for a given StatefulSet and checks if it's highly available
    ...    , if the replica counts are the expected / healthy values, and if not, what they should be.
    [Tags]
    ...    statefulset
    ...    replicas
    ...    desired
    ...    actual
    ...    available
    ...    ready
    ...    unhealthy
    ...    rollout
    ...    stuck
    ...    pods
    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get statefulset -n ${NAMESPACE} -o json --context ${CONTEXT} | jq -r '.items[] | select(.status.availableReplicas < .status.replicas) | "---\\nStatefulSet Name: " + (.metadata.name|tostring) + "\\nDesired Replicas: " + (.status.replicas|tostring) + "\\nAvailable Replicas: " + (.status.availableReplicas|tostring)'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${statefulset}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get statefulset ${LABELS} --context=${CONTEXT} -n ${NAMESPACE} -o json | jq -r 'if (.items | length) > 0 then .items[0] else {} end'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${available_replicas}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${statefulset}
    ...    extract_path_to_var__available_replicas=status.availableReplicas || `0`
    ...    available_replicas__raise_issue_if_lt=1
    ...    set_issue_title=No Available Replicas for Statefulset In Namespace ${NAMESPACE}
    ...    set_issue_details=No ready/available statefulset pods found for the statefulset with labels ${LABELS} in namespace ${NAMESPACE}, check events, namespace events, helm charts or kustomization objects.
    ...    assign_stdout_from_var=available_replicas
    ${desired_replicas}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${statefulset}
    ...    extract_path_to_var__desired_replicas=status.replicas || `0`
    ...    desired_replicas__raise_issue_if_lt=1
    ...    set_issue_title=No Desired Replicas For Statefulset In Namespace ${NAMESPACE}
    ...    set_issue_details=No desired replicas for statefulset under labels ${LABELS} in namespace ${NAMESPACE}, check if the statefulset has been scaled down.
    ...    assign_stdout_from_var=desired_replicas
    ${desired_replicas}=    Convert To Number    ${desired_replicas.stdout}
    ${available_replicas}=    Convert To Number    ${available_replicas.stdout}
    RW.Core.Add Pre To Report    StatefulSet State:\n${StatefulSet}
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
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for CLI commands
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${STATEFULSET_NAME}    ${STATEFULSET_NAME}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
    IF    "${LABELS}" != ""
        ${LABELS}=    Set Variable    -l ${LABELS}
    END
    Set Suite Variable    ${LABELS}    ${LABELS}
