*** Settings ***
Documentation       A suite of tasks that can be used to triage potential issues in your vault namespace.
Metadata            Author    jon-funk
Metadata            Display Name    Kubernetes Vault Triage
Metadata            Supports    AKS,EKS,GKE,Kubernetes,Vault

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.K8sHelper
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Fetch Vault CSI Driver Logs in Namespace `${NAMESPACE}`
    [Documentation]    Fetches the last 100 lines of logs for the vault CSI driver.
    [Tags]    access:read-only  fetch    log    pod    container    errors    inspect    trace    info    vault    csi    driver
    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} logs --tail=100 daemonset.apps/vault-csi-provider --context ${CONTEXT} -n ${NAMESPACE}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${found_logs}=    Set Variable    No Vault CSI driver logs found!
    IF    """${logs.stdout}""" != ""
        ${found_logs}=    Set Variable    ${logs.stdout}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${found_logs}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Get Vault CSI Driver Warning Events in `${NAMESPACE}`
    [Documentation]    Fetches warning-type events related to the vault CSI driver.
    [Tags]    access:read-only  events    errors    warnings    get    vault    csi    driver
    ${events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --field-selector type=Warning --context ${CONTEXT} -n ${NAMESPACE} | grep -i "vault-csi-provider" || true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
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
    ...    access:read-only
    ${daemonset_describe}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} describe daemonset.apps/vault-csi-provider --context ${CONTEXT} -n ${NAMESPACE}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${daemonset}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get daemonset.apps/vault-csi-provider --context ${CONTEXT} -n ${NAMESPACE} -o json
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    # status fields
    ${current_scheduled}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${daemonset}
    ...    extract_path_to_var__current_scheduled=status.currentNumberScheduled || `0`
    ...    assign_stdout_from_var=current_scheduled
    # Check if current scheduled pods is less than 1
    ${current_scheduled_value}=    Convert To Number    ${current_scheduled.stdout}
    IF    ${current_scheduled_value} < 1
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=At least 1 vault csi driver daemonset pod should be scheduled
        ...    actual=Current scheduled pods: ${current_scheduled_value}
        ...    title=Vault CSI Driver DaemonSet Scheduling Issue in Namespace `${NAMESPACE}`
        ...    details=Scheduling issue with csi driver daemonset pods, check node health, events, and namespace events.
        ...    reproduce_hint=Check daemonset status and node health in the cluster
        ...    next_steps=Investigate node health, check daemonset events, and verify node selectors and taints
    END
    ${desired_scheduled}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${daemonset}
    ...    extract_path_to_var__desired_scheduled=status.desiredNumberScheduled || `0`
    ...    assign_stdout_from_var=desired_scheduled
    # Check if desired scheduled pods is less than 1
    ${desired_scheduled_value}=    Convert To Number    ${desired_scheduled.stdout}
    IF    ${desired_scheduled_value} < 1
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=At least 1 vault csi driver daemonset pod should be desired
        ...    actual=Desired scheduled pods: ${desired_scheduled_value}
        ...    title=Vault CSI Driver DaemonSet No Desired Pods in Namespace `${NAMESPACE}`
        ...    details=No csi driver daemonset pods ready, check the vault csi driver daemonset events, helm or kustomization objects, and configuration.
        ...    reproduce_hint=Check daemonset configuration and deployment status
        ...    next_steps=Review daemonset configuration, check helm charts or kustomization objects, and verify deployment settings
    END
    ${available}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${daemonset}
    ...    extract_path_to_var__available=status.numberAvailable || `0`
    ...    assign_stdout_from_var=available
    # Check if available pods is less than 1
    ${available_value}=    Convert To Number    ${available.stdout}
    IF    ${available_value} < 1
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=At least 1 vault csi driver daemonset pod should be available
        ...    actual=Available pods: ${available_value}
        ...    title=Vault CSI Driver DaemonSet No Available Pods in Namespace `${NAMESPACE}`
        ...    details=No csi driver daemonset pods available, check node health, events, and namespace events.
        ...    reproduce_hint=Check daemonset status and pod health
        ...    next_steps=Check pod logs, node health, and resource availability
    END
    ${misscheduled}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${daemonset}
    ...    extract_path_to_var__misscheduled=status.numberMisscheduled || `0`
    ...    assign_stdout_from_var=misscheduled
    # Check if misscheduled pods is greater than 0
    ${misscheduled_value}=    Convert To Number    ${misscheduled.stdout}
    IF    ${misscheduled_value} > 0
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=No vault csi driver daemonset pods should be misscheduled
        ...    actual=Misscheduled pods: ${misscheduled_value}
        ...    title=Vault CSI Driver DaemonSet Pods Misscheduled in Namespace `${NAMESPACE}`
        ...    details=Scheduling issue with csi driver daemonset pods, check node health, events, and namespace events.
        ...    reproduce_hint=Check daemonset status and node scheduling issues
        ...    next_steps=Check node labels, taints, and scheduling constraints
    END
    ${ready}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${daemonset}
    ...    extract_path_to_var__ready=status.numberReady || `0`
    ...    assign_stdout_from_var=ready
    # Check if ready pods is less than 1
    ${ready_value}=    Convert To Number    ${ready.stdout}
    IF    ${ready_value} < 1
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=At least 1 vault csi driver daemonset pod should be ready
        ...    actual=Ready pods: ${ready_value}
        ...    title=Vault CSI Driver DaemonSet No Ready Pods in Namespace `${NAMESPACE}`
        ...    details=No csi driver daemonset pods ready, check the vault csi driver daemonset events, helm or kustomization objects, and configuration.
        ...    reproduce_hint=Check daemonset status and pod readiness
        ...    next_steps=Check pod logs, readiness probes, and daemonset configuration
    END
    ${unavailable}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${daemonset}
    ...    extract_path_to_var__unavailable=status.numberUnavailable || `0`
    ...    assign_stdout_from_var=unavailable
    # Check if unavailable pods is greater than 0
    ${unavailable_pods}=    Convert To Number    ${unavailable.stdout}
    IF    ${unavailable_pods} > 0
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=No vault csi driver daemonset pods should be unavailable
        ...    actual=Unavailable pods: ${unavailable_pods}
        ...    title=Vault CSI Driver DaemonSet Pods Unavailable in Namespace `${NAMESPACE}`
        ...    details=Fewer than desired csi driver daemonset pods, check node health, events, and namespace events.
        ...    reproduce_hint=Check daemonset status and pod availability
        ...    next_steps=Check node capacity, pod resource requests, and cluster scaling
    END
    # spec fields
    ${max_unavailable}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${daemonset}
    ...    extract_path_to_var__max_unavailable=spec.updateStrategy.rollingUpdate.maxUnavailable || `0`
    ...    assign_stdout_from_var=max_unavailable
    # field comparisons
    # Note: unavailable was already converted to unavailable_pods on line 162
    # Note: available was already converted to available_value on line 114
    # Check if unavailable pods exceed max_unavailable threshold
    ${max_unavailable_value}=    Convert To Number    ${max_unavailable.stdout}
    IF    ${unavailable_pods} > ${max_unavailable_value}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Unavailable vault csi driver daemonset pods should not exceed max_unavailable threshold
        ...    actual=More unavailable vault csi driver daemonset pods (${unavailable_pods}) than configured max_unavailable (${max_unavailable_value})
        ...    title=Vault CSI Driver DaemonSet Exceeds Max Unavailable Threshold in Namespace `${NAMESPACE}`
        ...    details=More unavailable vault csi driver daemonset pods than configured max_unavailable, check node health, events, and namespace events. Cluster might be undergoing a scaling event or upgrade, but should not cause max_unavailable to be violated.
        ...    reproduce_hint=Check daemonset status and node health in the cluster
        ...    next_steps=Check if cluster is undergoing maintenance, verify node health, and review daemonset update strategy
    END
    # Check if current scheduled pods don't match available pods
    # Note: current_scheduled_value was already converted to number on line 82
    IF    ${current_scheduled_value} != ${available_value}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Current scheduled vault csi driver daemonset pods should match available pods
        ...    actual=Current scheduled pods (${current_scheduled_value}) do not match available pods (${available_value})
        ...    title=Vault CSI Driver DaemonSet Pod Count Mismatch in Namespace `${NAMESPACE}`
        ...    details=Fewer than desired csi driver daemonset pods, check node health, events, and namespace events. Cluster might be undergoing a scaling event or upgrade.
        ...    reproduce_hint=Check daemonset status and node health in the cluster
        ...    next_steps=Monitor daemonset rollout status and check for node scheduling issues
    END
    RW.Core.Add Pre To Report    Deployment State:\n${daemonset_describe.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Fetch Vault Pod Workload Logs in Namespace `${NAMESPACE}` with Labels `${LABELS}`
    [Documentation]    Fetches the last 100 lines of logs for all vault pod workloads in the vault namespace.
    [Tags]    access:read-only  fetch    log    pod    container    errors    inspect    trace    info    statefulset    vault
    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} logs --tail=100 statefulset.apps/vault --context ${CONTEXT} -n ${NAMESPACE}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${found_logs}=    Set Variable    No Vault logs found!
    IF    """${logs.stdout}""" != ""
        ${found_logs}=    Set Variable    ${logs.stdout}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${found_logs}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Get Related Vault Events in Namespace `${NAMESPACE}`
    [Documentation]    Fetches all warning-type events related to vault in the vault namespace.
    [Tags]   access:read-only   events    workloads    errors    warnings    get    statefulset    vault
    ${events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --field-selector type=Warning --context ${CONTEXT} -n ${NAMESPACE} | grep -i "vault" || true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${found_events}=    Set Variable    No Vault Events found!
    IF    """${events.stdout}""" != ""
        ${found_events}=    Set Variable    ${events.stdout}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${found_events}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Fetch Vault StatefulSet Manifest Details in `${NAMESPACE}`
    [Documentation]    Fetches the current state of the vault statefulset manifest for inspection.
    [Tags]    access:read-only  statefulset    details    manifest    info    vault
    ${statefulset}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get statefulset.apps/vault --context=${CONTEXT} -n ${NAMESPACE} -o yaml
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${statefulset.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Fetch Vault DaemonSet Manifest Details in Kubernetes Cluster `${NAMESPACE}`
    [Documentation]    Fetches the current state of the vault daemonset manifest for inspection.
    [Tags]    access:read-only  statefulset    details    manifest    info    vault
    ${statefulset}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get daemonset.apps/vault-csi-provider --context=${CONTEXT} -n ${NAMESPACE} -o yaml
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${statefulset.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Verify Vault Availability in Namespace `${NAMESPACE}` and Context `${CONTEXT}`
    [Documentation]    Curls the vault endpoint and checks the HTTP response code.
    [Tags]    access:read-only  http    curl    vault    web    code    ok    available
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=curl ${VAULT_URL}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    # Parse vault status from JSON response
    ${vault_status}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${rsp}
    ...    extract_path_to_var__init=initialized
    ...    extract_path_to_var__sealed=sealed
    ...    extract_path_to_var__standby=standby
    
    # Check vault initialization status
    ${init_status}=    Set Variable    ${vault_status.stdout}
    ${sealed_status}=    Evaluate    json.loads('${rsp.stdout}').get('sealed', True)    json
    ${initialized_status}=    Evaluate    json.loads('${rsp.stdout}').get('initialized', False)    json
    
    IF    ${initialized_status} != True or ${sealed_status} != False
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Vault should be initialized (True) and unsealed (False)
        ...    actual=Vault state - initialized: ${initialized_status}, sealed: ${sealed_status}
        ...    title=Vault API Responded With Error State in Namespace `${NAMESPACE}`
        ...    details=The vault state is init:${initialized_status}, sealed:${sealed_status}. Based on "${rsp.stdout}". Check statefulset pod logs and events. Verify or invoke unseal process.
        ...    reproduce_hint=Check vault pod logs and verify unseal process
        ...    next_steps=Check vault pod logs, verify unseal keys are available, and run unseal process if needed
    END

Check Vault StatefulSet Replicas in `NAMESPACE`
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
    ...    access:read-only
    ${statefulset}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get statefulset.apps/vault --context=${CONTEXT} -n ${NAMESPACE} -o json
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${available_replicas}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${statefulset}
    ...    extract_path_to_var__available_replicas=status.availableReplicas || `0`
    ...    assign_stdout_from_var=available_replicas
    # Check if available replicas is less than 1
    ${available_replicas_value}=    Convert To Number    ${available_replicas.stdout}
    IF    ${available_replicas_value} < 1
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=At least 1 vault server pod should be available
        ...    actual=Available replicas: ${available_replicas_value}
        ...    title=Vault StatefulSet No Available Replicas in Namespace `${NAMESPACE}`
        ...    details=No running vault server pods found, check node health, events, namespace events, helm charts or kustomization objects.
        ...    reproduce_hint=Check statefulset status and pod health
        ...    next_steps=Check statefulset configuration, pod logs, and verify helm chart or kustomization deployment
    END
    ${desired_replicas}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${statefulset}
    ...    extract_path_to_var__desired_replicas=status.replicas || `0`
    ...    assign_stdout_from_var=desired_replicas
    # Check if desired replicas is less than 1
    ${desired_replicas_value}=    Convert To Number    ${desired_replicas.stdout}
    IF    ${desired_replicas_value} < 1
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=At least 1 vault server pod should be desired
        ...    actual=Desired replicas: ${desired_replicas_value}
        ...    title=Vault StatefulSet No Desired Replicas in Namespace `${NAMESPACE}`
        ...    details=No vault server pods desired, check if the vault instance has been scaled down.
        ...    reproduce_hint=Check statefulset configuration and scaling settings
        ...    next_steps=Check statefulset replica configuration and verify if scaling down was intentional
    END
    # Check if desired replicas matches available replicas
    IF    ${desired_replicas_value} != ${available_replicas_value}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=Desired replicas should match available replicas
        ...    actual=Desired replicas (${desired_replicas_value}) does not match available replicas (${available_replicas_value})
        ...    title=Vault StatefulSet Replica Count Mismatch in Namespace `${NAMESPACE}`
        ...    details=Desired replicas for vault does not match available/ready, check namespace and statefulset events, check node events or scaling events.
        ...    reproduce_hint=Check statefulset status and scaling events
        ...    next_steps=Monitor statefulset rollout, check pod startup logs, and verify resource availability
    END
    # Note: desired_replicas and available_replicas were already converted to numbers earlier
    RW.Core.Add Pre To Report    StatefulSet State:\n${statefulset.stdout}
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
    ${VAULT_URL}=    RW.Core.Import User Variable    VAULT_URL
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
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}

    # Verify cluster connectivity
    RW.K8sHelper.Verify Cluster Connectivity
    ...    binary=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    context=${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    Set Suite Variable    ${VAULT_URL}    ${VAULT_URL}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    IF    "${LABELS}" != ""
        ${LABELS}=    Set Variable    -l ${LABELS}
    END
    Set Suite Variable    ${LABELS}    ${LABELS}
