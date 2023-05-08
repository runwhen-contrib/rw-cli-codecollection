*** Settings ***
Metadata          Author    Jonathan Funk
Metadata          Display Name    Kubernetes Artifactory Triage
Metadata          Supports    Kubernetes,AKS,EKS,GKE,OpenShift,Artifactory
Documentation     Performs a triage on the Open Source version of Artifactory in a Kubernetes cluster.
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
    ...    description=The name of the Artifactory statefulset.
    ...    pattern=\w*
    ...    example=artifactory-oss
    ...    default=artifactory-oss
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=The name of the Kubernetes namespace that the Artifactory workloads reside in.
    ...    pattern=\w*
    ...    example=artifactory
    ...    default=artifactory
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
    ${EXPECTED_AVAILABILITY}=    RW.Core.Import User Variable    EXPECTED_AVAILABILITY
    ...    type=string
    ...    description=The minimum numbers of replicas allowed considered healthy.
    ...    pattern=\d+
    ...    example=2
    ...    default=2
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
    Set Suite Variable    ${EXPECTED_AVAILABILITY}    ${EXPECTED_AVAILABILITY}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
    IF    "${LABELS}" != ""
        ${LABELS}=    Set Variable    -l ${LABELS}        
    END
    Set Suite Variable    ${LABELS}    ${LABELS}


*** Tasks ***
Fetch Artifactory Logs
    [Documentation]    Fetches the last 100 lines of logs for the Artifactory StatefulSet in the namespace.
    [Tags]    Fetch    Log    Pod    Container    Errors    Inspect    Trace    Info    StatefulSet
    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} logs --tail=100 statefulset/${STATEFULSET_NAME} --context ${CONTEXT} -n ${NAMESPACE}
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${logs.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Get Related Artifactory Events
    [Documentation]    Fetches events related to the Artifactory StatefulSet workload in the namespace.
    [Tags]    Events    Workloads    Errors    Warnings    Get    StatefulSet
    ${events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --field-selector type=Warning --context ${CONTEXT} -n ${NAMESPACE} | grep -i "${STATEFULSET_NAME}"
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${events.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Fetch Artifactory StatefulSet Manifest Details
    [Documentation]    Fetches the current state of the Artifactory StatefulSet manifest for inspection.
    [Tags]    StatefulSet    Details    Manifest    Info
    ${statefulset}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get statefulset ${LABELS} --context=${CONTEXT} -n ${NAMESPACE} -o yaml
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${statefulset.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check Artifactory StatefulSet Replicas
    [Documentation]    Pulls the replica information for the Artifactory StatefulSet and checks if it's highly available
    ...                , if the replica counts are the expected / healthy values, and if not, what they should be.
    [Tags]    StatefulSet    Replicas    Desired    Actual    Available    Ready    Unhealthy    Rollout    Stuck    Pods
    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get statefulset -n ${NAMESPACE} -o json | jq -r '.items[] | select(.status.availableReplicas < .status.replicas) | "---\nStatefulSet Name: " + (.metadata.name|tostring) + "\nDesired Replicas: " + (.status.replicas|tostring) + "\nAvailable Replicas: " + (.status.availableReplicas|tostring)'  
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${statefulset}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get statefulset/${STATEFULSET_NAME} ${LABELS} --context=${CONTEXT} -n ${NAMESPACE} -ojson
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
    ...    available_replicas__raise_issue_if_lt=${EXPECTED_AVAILABILITY}
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

Check Artifactory Health Endpoints
    [Documentation]    Runs a set of exec commands internally in the Artifactory workloads to curl the system health endpoints.
    [Tags]    Pods    Statefulset    Artifactory    Health    System    Curl    API    OK    HTTP
    # these endpoints dont respect json type headers
    ${liveness}=    RW.CLI.Run Cli
    ...    cmd=kubectl exec statefulset/${STATEFULSET_NAME} -- curl -k --max-time 10 http://localhost:8091/artifactory/api/v1/system/liveness
    ...    env=${env}
    ...    run_in_workload_with_name=
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    render_in_commandlist=true
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${liveness}
    ...    set_severity_level=2
    ...    set_issue_title=The liveness endpoint did not respond with OK
    ...    _line__raise_issue_if_ncontains=OK
    ${readiness}=    RW.CLI.Run Cli
    ...    cmd=kubectl exec statefulset/${STATEFULSET_NAME} -- curl -k --max-time 10 http://localhost:8091/artifactory/api/v1/system/readiness
    ...    env=${env}
    ...    secret_file__kubeconfig=${KUBECONFIG}
    ...    render_in_commandlist=true
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${readiness}
    ...    set_severity_level=2
    ...    set_issue_title=The readiness endpoint did not respond with OK
    ...    _line__raise_issue_if_ncontains=OK
    # TODO: add task to test download of artifact objects
    # TODO: figure out how to do implicit auth without passing in secrets
    # ${topology}=    RW.CLI.Run Cli
    # ...    cmd=curl -k --max-time 10 http://localhost:8091/artifactory/api/v1/system/topology/health -H 'Content-Type: application/json'
    # ...    env=${env}
    # ...    run_in_workload_with_name=statefulset/${STATEFULSET_NAME} 
    # ...    optional_namespace=${NAMESPACE}
    # ...    optional_context=${CONTEXT}
    # ...    secret_file__kubeconfig=${KUBECONFIG}
    # ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${liveness.stdout}
    RW.Core.Add Pre To Report    ${readiness.stdout}
    # RW.Core.Add Pre To Report    ${topology.stdout}