*** Settings ***
Metadata          Author    Jonathan Funk
Metadata          Display Name    Kubernetes Deployment Triage
Metadata          Supports    Kubernetes,AKS,EKS,GKE,OpenShift
Documentation     Triages issues related to a deployment and its replicas.
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
    ${DEPLOYMENT_NAME}=    RW.Core.Import User Variable    DEPLOYMENT_NAME
    ...    type=string
    ...    description=Used to target the resource for queries and filtering events.
    ...    pattern=\w*
    ...    example=artifactory
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
    ${EXPECTED_AVAILABILITY}=    RW.Core.Import User Variable    EXPECTED_AVAILABILITY
    ...    type=string
    ...    description=The minimum numbers of replicas allowed considered healthy.
    ...    pattern=\d+
    ...    example=3
    ...    default=3
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${DEPLOYMENT_NAME}    ${DEPLOYMENT_NAME}
    Set Suite Variable    ${EXPECTED_AVAILABILITY}    ${EXPECTED_AVAILABILITY}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}

*** Tasks ***
Fetch Deployment Logs
    [Documentation]    Fetches the last 100 lines of logs for the given deployment in the namespace.
    [Tags]    Fetch    Log    Pod    Container    Errors    Inspect    Trace    Info    Deployment
    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} logs --tail=100 deployment/${DEPLOYMENT_NAME} --context ${CONTEXT} -n ${NAMESPACE}
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${logs.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Get Related Deployment Events
    [Documentation]    Fetches events related to the deployment workload in the namespace.
    [Tags]    Events    Workloads    Errors    Warnings    Get    Deployment
    ${events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --context ${CONTEXT} -n ${NAMESPACE} --field-selector type=Warning | grep -i "${DEPLOYMENT_NAME}"
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${events}
    ...    set_severity_level=1
    ...    set_issue_expected=No events of type warning should exist for deployment. 
    ...    set_issue_actual=Events of type warning found for deployment. 
    ...    set_issue_title=The deployment ${DEPLOYMENT_NAME} has warning events!
    ...    set_issue_details=Warning events found for deployment ${DEPLOYMENT_NAME} in namespace ${NAMESPACE} eg: $_line \n - check event output and related nodes, persistent volumes, persistent volume claims, image registry authenticaiton, or fluxcd or argocd logs. 
    ...    _line__raise_issue_if_contains=Warning
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${events.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Fetch Deployment Manifest Details
    [Documentation]    Fetches the current state of the deployment manifest for inspection.
    [Tags]    Deployment    Details    Manifest    Info
    ${deployment}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment/${DEPLOYMENT_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o yaml
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${deployment.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check Deployment Replicas
    [Documentation]    Pulls the replica information for a given deployment and checks if it's highly available
    ...                , if the replica counts are the expected / healthy values, and if not, what they should be.
    [Tags]    Deployment    Replicas    Desired    Actual    Available    Ready    Unhealthy    Rollout    Stuck    Pods
    ${deployment}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get deployment/${DEPLOYMENT_NAME} --context ${CONTEXT} -n ${NAMESPACE} -o json
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${available_replicas}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${deployment}
    ...    extract_path_to_var__available_replicas=status.availableReplicas || `0`
    ...    available_replicas__raise_issue_if_lt=1
    ...    assign_stdout_from_var=available_replicas
    ...    set_issue_title=No replicas available for deployment/${DEPLOYMENT_NAME}
    ...    set_issue_details=No replicas available for deployment/${DEPLOYMENT_NAME} in namespace ${NAMESPACE}, we found 0. Check deployment has not been scaled down, deployment events, persistent volumes, deployment configuration, or applicable fluxcd or argo gitops configurations or status.
    RW.CLI.Parse Cli Json Output
    ...    rsp=${available_replicas}
    ...    extract_path_to_var__available_replicas=@
    ...    available_replicas__raise_issue_if_lt=${EXPECTED_AVAILABILITY}
    ...    set_issue_title=Fewer Than Expected Available Replicas For Deployment ${DEPLOYMENT_NAME}
    ...    set_issue_details=Fewer than expected replicas available (we found $available_replicas) for deployment ${DEPLOYMENT_NAME} in namespace ${NAMESPACE} - check manifests, kubernetes events, pod logs, resource constraints and persistent volumes
    ${desired_replicas}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${deployment}
    ...    extract_path_to_var__desired_replicas=status.replicas || `0`
    ...    desired_replicas__raise_issue_if_lt=1
    ...    assign_stdout_from_var=desired_replicas
    ...    set_issue_title=Less than desired replicas for deployment/${DEPLOYMENT_NAME}
    ...    set_issue_details=Less than desired replicas for deployment/${DEPLOYMENT_NAME} in ${NAMESPACE}. Check deployment has not been scaled down, deployment events, persistent volumes, deployment configuration, or applicable fluxcd or argo gitops configurations or status.
    RW.CLI.Parse Cli Json Output
    ...    rsp=${desired_replicas}
    ...    extract_path_to_var__desired_replicas=@
    ...    desired_replicas__raise_issue_if_neq=${available_replicas.stdout}
    ...    set_issue_title=Desired and ready pods for deployment/${DEPLOYMENT_NAME} do not match as expected!
    ...    set_issue_details=Desired and ready pods for deployment/${DEPLOYMENT_NAME} do not match in namespace ${NAMESPACE}, desired: $desired_replicas vs ready: ${available_replicas.stdout}. We got ready:${available_replicas.stdout} vs desired: $desired_replicas - check deployment events, deployment configuration, persistent volumes, or applicable fluxcd or argo gitops configurations or status. Check node events, or if the cluster is undergoing a scaling event or upgrade. Check cloud provider service availability for any known outages. 
    ${desired_replicas}=    Convert To Number    ${desired_replicas.stdout}
    ${available_replicas}=    Convert To Number    ${available_replicas.stdout}
    RW.Core.Add Pre To Report    Deployment State:\n${deployment.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
