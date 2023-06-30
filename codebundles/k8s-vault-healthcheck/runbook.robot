*** Settings ***
Documentation       A suite of tasks that can be used to triage potential issues in your vault namespace.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Vault Triage
Metadata            Supports    AKS,EKS,GKE,Kubernetes,Vault

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Fetch Vault CSI Driver Logs
    [Documentation]    Fetches the last 100 lines of logs for the vault CSI driver.
    [Tags]    fetch    log    pod    container    errors    inspect    trace    info    vault    csi    driver
    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} logs --tail=100 daemonset.apps/vault-csi-provider --context ${CONTEXT} -n ${NAMESPACE}
    ...    env=${env}
    ...    target_service=${kubectl}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${found_logs}=    Set Variable    No Vault CSI driver logs found!
    IF    """${logs.stdout}""" != ""
        ${found_logs}=    Set Variable    ${logs.stdout}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${found_logs}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Get Vault CSI Driver Warning Events
    [Documentation]    Fetches warning-type events related to the vault CSI driver.
    [Tags]    events    errors    warnings    get    vault    csi    driver
    ${events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --field-selector type=Warning --context ${CONTEXT} -n ${NAMESPACE} | grep -i "vault-csi-provider" || true
    ...    env=${env}
    ...    target_service=${kubectl}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${found_events}=    Set Variable    No Vault CSI driver Events found!
    IF    """${events.stdout}""" != ""
        ${found_events}=    Set Variable    ${events.stdout}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${found_events}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check Vault CSI Driver Replicas
    [Documentation]    Performs an inspection on the replicas of the vault CSI driver daemonset.
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
    ${daemonset_describe}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} describe daemonset.apps/vault-csi-provider --context ${CONTEXT} -n ${NAMESPACE}
    ...    env=${env}
    ...    target_service=${kubectl}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${daemonset}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get daemonset.apps/vault-csi-provider --context ${CONTEXT} -n ${NAMESPACE} -o json
    ...    env=${env}
    ...    target_service=${kubectl}
    ...    secret_file__kubeconfig=${kubeconfig}
    # status fields
    ${current_scheduled}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${daemonset}
    ...    extract_path_to_var__current_scheduled=status.currentNumberScheduled || `0`
    ...    current_scheduled__raise_issue_if_lt=1
    ...    set_issue_details=Scheduling issue with csi driver daemonset pods, check node health, events, and namespace events.
    ...    assign_stdout_from_var=current_scheduled
    ${desired_scheduled}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${daemonset}
    ...    extract_path_to_var__desired_scheduled=status.desiredNumberScheduled || `0`
    ...    desired_scheduled__raise_issue_if_lt=1
    ...    set_issue_details=No csi driver daemonset pods ready, check the vault csi driver daemonset events, helm or kustomization objects, and configuration.
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
    ...    set_issue_details=Scheduling issue with csi driver daemonset pods, check node health, events, and namespace events.
    ...    assign_stdout_from_var=misscheduled
    ${ready}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${daemonset}
    ...    extract_path_to_var__ready=status.numberReady || `0`
    ...    ready__raise_issue_if_lt=1
    ...    set_issue_details=No csi driver daemonset pods ready, check the vault csi driver daemonset events, helm or kustomization objects, and configuration.
    ...    assign_stdout_from_var=ready
    ${unavailable}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${daemonset}
    ...    extract_path_to_var__unavailable=status.numberUnavailable || `0`
    ...    unavailable__raise_issue_if_gt=0
    ...    set_issue_details=Fewer than desired csi driver daemonset pods, check node health, events, and namespace events.
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
    ...    set_issue_details=More unavailable vault csi driver daemonset pods than configured max_unavailable, check node health, events, and namespace events. Cluster might be undergoing a scaling event or upgrade, but should not cause max_unavailable to be violated.
    RW.CLI.Parse Cli Json Output
    ...    rsp=${current_scheduled}
    ...    extract_path_to_var__comparison=@
    ...    comparison__raise_issue_if_neq=${available}
    ...    set_issue_details=Fewer than desired csi driver daemonset pods, check node health, events, and namespace events. Cluster might be undergoing a scaling event or upgrade.
    RW.Core.Add Pre To Report    Deployment State:\n${daemonset_describe.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Fetch Vault Logs
    [Documentation]    Fetches the last 100 lines of logs for all vault pod workloads in the vault namespace.
    [Tags]    fetch    log    pod    container    errors    inspect    trace    info    statefulset    vault
    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} logs --tail=100 statefulset.apps/vault --context ${CONTEXT} -n ${NAMESPACE}
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${found_logs}=    Set Variable    No Vault logs found!
    IF    """${logs.stdout}""" != ""
        ${found_logs}=    Set Variable    ${logs.stdout}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${found_logs}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Get Related Vault Events
    [Documentation]    Fetches all warning-type events related to vault in the vault namespace.
    [Tags]    events    workloads    errors    warnings    get    statefulset    vault
    ${events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --field-selector type=Warning --context ${CONTEXT} -n ${NAMESPACE} | grep -i "vault" || true
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${found_events}=    Set Variable    No Vault Events found!
    IF    """${events.stdout}""" != ""
        ${found_events}=    Set Variable    ${events.stdout}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${found_events}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Fetch Vault StatefulSet Manifest Details
    [Documentation]    Fetches the current state of the vault statefulset manifest for inspection.
    [Tags]    statefulset    details    manifest    info    vault
    ${statefulset}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get statefulset.apps/vault --context=${CONTEXT} -n ${NAMESPACE} -o yaml
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${statefulset.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Fetch Vault DaemonSet Manifest Details
    [Documentation]    Fetches the current state of the vault daemonset manifest for inspection.
    [Tags]    statefulset    details    manifest    info    vault
    ${statefulset}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get daemonset.apps/vault-csi-provider --context=${CONTEXT} -n ${NAMESPACE} -o yaml
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${statefulset.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Verify Vault Availability
    [Documentation]    Curls the vault endpoint and checks the HTTP response code.
    [Tags]    http    curl    vault    web    code    ok    available
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=curl ${VAULT_URL}
    ...    render_in_commandlist=true
    RW.CLI.Parse Cli Json Output
    ...    rsp=${rsp}
    ...    extract_path_to_var__init=initialized
    ...    extract_path_to_var__sealed=sealed
    ...    extract_path_to_var__standby=standby
    ...    init__raise_issue_if_neq=True
    ...    sealed__raise_issue_if_neq=False
    ...    set_issue_title=The Vault API Responded With An Error State
    ...    set_issue_details=The vault state is init:$init, standby:$standby and sealed:$sealed. Based on "$_stdout". Check statefulset pod logs and events. Verify or invoke unseal process.

Check Vault StatefulSet Replicas
    [Documentation]    Pulls the replica information for the Vault statefulset and checks if it's highly available
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
    ...    vault
    ${statefulset}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get statefulset.apps/vault --context=${CONTEXT} -n ${NAMESPACE} -o json
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${available_replicas}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${statefulset}
    ...    extract_path_to_var__available_replicas=status.availableReplicas || `0`
    ...    available_replicas__raise_issue_if_lt=1
    ...    set_issue_details=No running vault server pods found, check node health, events, namespace events, helm charts or kustomization objects.
    ...    assign_stdout_from_var=available_replicas
    ${desired_replicas}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${statefulset}
    ...    extract_path_to_var__desired_replicas=status.replicas || `0`
    ...    desired_replicas__raise_issue_if_lt=1
    ...    assign_stdout_from_var=desired_replicas
    ...    set_issue_details=No vault server pods desired, check if the vault instance has been scaled down.
    RW.CLI.Parse Cli Json Output
    ...    rsp=${desired_replicas}
    ...    extract_path_to_var__desired_replicas=@
    ...    desired_replicas__raise_issue_if_neq=${available_replicas.stdout}
    ...    set_issue_details=Desired replicas for vault does not match available/ready, check namespace and statefulset events, check node events or scaling events.
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
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=The namespace that your vault workloads reside in. Typically 'vault'.
    ...    pattern=\w*
    ...    example=vault
    ...    default=vault
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
    ${LABELS}=    RW.Core.Import User Variable    LABELS
    ...    type=string
    ...    description=Additional labels to use when selecting vault resources during triage.
    ...    pattern=\w*
    ...    example=Could not render example.
    ${VAULT_URL}=    RW.Core.Import User Variable    LABELS
    ...    type=string
    ...    description=The URL of the vault instance to check.
    ...    pattern=\w*
    ...    example=https://myvault.com/v1/sys/health
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
    Set Suite Variable    ${VAULT_URL}    ${VAULT_URL}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    IF    "${LABELS}" != ""
        ${LABELS}=    Set Variable    -l ${LABELS}
    END
    Set Suite Variable    ${LABELS}    ${LABELS}
