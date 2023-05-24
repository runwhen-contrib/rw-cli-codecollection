*** Settings ***
Documentation       This taskset collects information about perstistent volumes and persistent volume claims to 
...    validate health or help troubleshoot potential issues.
Metadata            Author    Jonathan Funk
Metadata            Display Name    Kubernetes Jenkins Healthcheck
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift,Jenkins
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             DateTime
Library             Collections

Suite Setup         Suite Initialization


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
    ...    example=my-main-cluster
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=The name of the namespace to search.   
    ...    pattern=\w*
    ...    example=otel-demo
    ...    default=
    ${STATEFULSET_NAME}=    RW.Core.Import User Variable    STATEFULSET_NAME
    ...    type=string
    ...    description=Used to target the resource for queries and filtering events.
    ...    pattern=\w*
    ...    example=jenkins
    ${LABELS}=    RW.Core.Import User Variable    LABELS
    ...    type=string
    ...    description=The Kubernetes labels used to fetch the first matching statefulset.
    ...    pattern=\w*
    ...    example=Could not render example.
    ...    default=
    ${JENKINS_SA_USERNAME}=    RW.Core.Import Secret   JENKINS_SA_USERNAME
    ...    type=string
    ...    description=The username associated with the API token, typically the username.
    ...    pattern=\w*
    ...    example=my-username
    ...    default=
    ${JENKINS_SA_TOKEN}=    RW.Core.Import Secret    JENKINS_SA_TOKEN
    ...    type=string
    ...    description=The API token generated and managed by jenkins in the user configuration settings.
    ...    pattern=\w*
    ...    example=my-secret-token
    ...    default=
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${STATEFULSET_NAME}    ${STATEFULSET_NAME}
    Set Suite Variable    ${JENKINS_SA_USERNAME}    ${JENKINS_SA_USERNAME}
    Set Suite Variable    ${JENKINS_SA_TOKEN}    ${JENKINS_SA_TOKEN}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
    IF    "${LABELS}" != ""
        ${LABELS}=    Set Variable    -l ${LABELS}        
    END
    Set Suite Variable    ${LABELS}    ${LABELS}

*** Tasks ***
Fetch Events for Unhealthy Jenkins Kubernetes PersistentVolumeClaims
    [Documentation]    Lists events related to persistent volume claims within the Jenkins namespace that are not bound to a persistent volume.
    [Tags]    PVC    List    Kubernetes    Storage    PersistentVolumeClaim    PersistentVolumeClaims Events    Jenkins
    ${unbound_pvc_events}=    RW.CLI.Run Cli
    ...    cmd=for pvc in $(${KUBERNETES_DISTRIBUTION_BINARY} get pvc -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.items[] | select(.status.phase != "Bound") | .metadata.name'); do ${KUBERNETES_DISTRIBUTION_BINARY} get events -n ${NAMESPACE} --context ${CONTEXT} --field-selector involvedObject.name=$pvc -o json | jq '.items[]| "Last Timestamp: " + .lastTimestamp + " Name: " + .involvedObject.name + " Message: " + .message'; done
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${unbound_pvc_events}
    ...    set_severity_level=1
    ...    set_issue_expected=PVCs should be bound
    ...    set_issue_actual=PVCs found pending with the following events
    ...    set_issue_title=PVC Errors & Events
    ...    set_issue_details=Review list of unbound persistent volume claims - check node events, application configurations, storage classes and CSI drivers. 
    ...    _line__raise_issue_if_contains=Name
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of events for unbound pvc in ${NAMESPACE}:
    RW.Core.Add Pre To Report    ${unbound_pvc_events.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

List PersistentVolumes in Terminating State
    [Documentation]    Lists events related to persistent volumes in Terminating state.
    [Tags]    PV    List    Kubernetes    Storage    PersistentVolume    Terminating    Events    Jenkins
    ${dangline_pvcs}=    RW.CLI.Run Cli
    ...    cmd=for pv in $(${KUBERNETES_DISTRIBUTION_BINARY} get pv --context ${CONTEXT} -o json | jq -r '.items[] | select(.status.phase == "Terminating") | .metadata.name'); do ${KUBERNETES_DISTRIBUTION_BINARY} get events --all-namespaces --field-selector involvedObject.name=$pv --context ${CONTEXT} -o json | jq '.items[]| "Last Timestamp: " + .lastTimestamp + " Name: " + .involvedObject.name + " Message: " + .message'; done
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${dangline_pvcs}
    ...    set_severity_level=4
    ...    set_issue_expected=PV should not be stuck terminating. 
    ...    set_issue_actual=PV is in a terminating state. 
    ...    set_issue_title=PV Events While Terminating
    ...    set_issue_details=Check the status of terminating pvcs over the next few minutes, they should disappear. If not, check that deployments or statefulsets attached to the pvc are scaled down and pods attached to the PVC are not running.  
    ...    _line__raise_issue_if_contains=Name
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of events for dangling persistent volumes:
    RW.Core.Add Pre To Report    ${dangline_pvcs.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

List Pods In Jenkins Namespace with Attached Volumes and Related PersistentVolume Details
    [Documentation]    For each pod in the configured jenkins namespace, collect details on configured persistent volume claim, persistent volume, and node.
    [Tags]    Pod    Storage    PVC    PV    Status    CSI    StorageReport    Jenkins
    ${pod_storage_report}=    RW.CLI.Run Cli
    ...    cmd=for pod in $(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n ${NAMESPACE} --field-selector=status.phase=Running --context ${CONTEXT} -o jsonpath='{range .items[*]}{.metadata.name}{"\\n"}{end}'); do for pvc in $(${KUBERNETES_DISTRIBUTION_BINARY} get pods $pod -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{range .spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\\n"}{end}'); do pv=$(${KUBERNETES_DISTRIBUTION_BINARY} get pvc $pvc -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.volumeName}') && status=$(${KUBERNETES_DISTRIBUTION_BINARY} get pv $pv --context ${CONTEXT} -o jsonpath='{.status.phase}') && node=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $pod -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.nodeName}') && zone=$(${KUBERNETES_DISTRIBUTION_BINARY} get nodes $node --context ${CONTEXT} -o jsonpath='{.metadata.labels.topology\\.kubernetes\\.io/zone}') && ingressclass=$(${KUBERNETES_DISTRIBUTION_BINARY} get pvc $pvc -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.storageClassName}') && accessmode=$(${KUBERNETES_DISTRIBUTION_BINARY} get pvc $pvc -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.status.accessModes[0]}') && reclaimpolicy=$(${KUBERNETES_DISTRIBUTION_BINARY} get pv $pv --context ${CONTEXT} -o jsonpath='{.spec.persistentVolumeReclaimPolicy}') && csidriver=$(${KUBERNETES_DISTRIBUTION_BINARY} get pv $pv --context ${CONTEXT} -o jsonpath='{.spec.csi.driver}')&& echo -e "\\n---\\nPod: $pod\\nPVC: $pvc\\nPV: $pv\\nStatus: $status\\nNode: $node\\nZone: $zone\\nIngressClass: $ingressclass\\nAccessModes: $accessmode\\nReclaimPolicy: $reclaimpolicy\\nCSIDriver: $csidriver\\n"; done; done
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of configured persistent volumes in ${NAMESPACE}:
    RW.Core.Add Pre To Report    ${pod_storage_report.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Fetch the Storage Utilization for PVC Mounts In The Jenkins Namespace
    [Documentation]    For each pod in the configured jenkins namespace, get the utilization of the pvc mount using the linux df command. Requires kubectl exec permissions.
    [Tags]    Pod    Storage    PVC    Storage    Utilization    Capacity    PersistentVolumeClaim
    ${pod_pvc_utilization}=    RW.CLI.Run Cli
    ...    cmd=for pod in $(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n ${NAMESPACE} --field-selector=status.phase=Running --context ${CONTEXT} -o jsonpath='{range .items[*]}{.metadata.name}{"\\n"}{end}'); do for pvc in $(${KUBERNETES_DISTRIBUTION_BINARY} get pods $pod -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{range .spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\\n"}{end}'); do for volumeName in $(${KUBERNETES_DISTRIBUTION_BINARY} get pod $pod -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.spec.volumes[] | select(has("persistentVolumeClaim")) | .name'); do mountPath=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $pod -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r --arg vol "$volumeName" '.spec.containers[].volumeMounts[] | select(.name == $vol) | .mountPath'); containerName=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $pod -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r --arg vol "$volumeName" '.spec.containers[] | select(.volumeMounts[].name == $vol) | .name'); echo -e "\\n---\\nPod: $pod, PVC: $pvc, volumeName: $volumeName, containerName: $containerName, mountPath: $mountPath"; ${KUBERNETES_DISTRIBUTION_BINARY} exec $pod -n ${NAMESPACE} --context ${CONTEXT} -c $containerName -- df -h $mountPath; done; done; done;
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${regexp}=     Evaluate   r'.*\\s(?P<pvc_utilization>\\d+)%'
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${pod_pvc_utilization}
    ...    lines_like_regexp=${regexp}
    ...    set_severity_level=2
    ...    set_issue_expected=PVC should be less than 95% utilized. 
    ...    set_issue_actual=PVC is 95% or greater. 
    ...    set_issue_title=PVC Storage Utilization As Report by Pod
    ...    set_issue_details=Review any storage utilization above 95% as they will be at or nearing capacity. Expand PVCs, remove uneeded storage, or check application configuration such as database logs and backup jobs.  
    ...    pvc_utilization__raise_issue_if_gt=95
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of PVC storage mount utilization in ${NAMESPACE}:
    RW.Core.Add Pre To Report    ${pod_pvc_utilization.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Fetch Jenkins StatefulSet Logs
    [Documentation]    Fetches the last 100 lines of logs for the given statefulset in the Jenkins namespace.
    [Tags]    Fetch    Log    Pod    Container    Errors    Inspect    Trace    Info    StatefulSet    Jenkins
    ${logs}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} logs --tail=100 statefulset/${STATEFULSET_NAME} --context ${CONTEXT} -n ${NAMESPACE}
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${logs.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Get Related Jenkins StatefulSet Events
    [Documentation]    Fetches events related to the Jenkins StatefulSet workload in the namespace.
    [Tags]    Events    Workloads    Errors    Warnings    Get    StatefulSet    Jenkins
    ${events}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get events --field-selector type=Warning --context ${CONTEXT} -n ${NAMESPACE} | grep -i "${STATEFULSET_NAME}"
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    ${events.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Fetch Jenkins StatefulSet Manifest Details
    [Documentation]    Fetches the current state of the Jenkins statefulset manifest for inspection.
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

Check Jenkins StatefulSet Replicas
    [Documentation]    Pulls the replica information for the Jenkins StatefulSet and checks if it's highly available
    ...                , if the replica counts are the expected / healthy values, and if not, what they should be.
    [Tags]    StatefulSet    Replicas    Desired    Actual    Available    Ready    Unhealthy    Rollout    Stuck    Pods    Jenkins
    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get statefulset ${LABELS} -n ${NAMESPACE} -o json --context ${CONTEXT} | jq -r '.items[] | select(.status.availableReplicas < .status.replicas) | "---\nStatefulSet Name: " + (.metadata.name|tostring) + "\nDesired Replicas: " + (.status.replicas|tostring) + "\nAvailable Replicas: " + (.status.availableReplicas|tostring)'  
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${statefulset}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} get statefulset ${LABELS} --context=${CONTEXT} -n ${NAMESPACE} -o=jsonpath='{.items[0]}'
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${available_replicas}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${statefulset}
    ...    extract_path_to_var__available_replicas=status.availableReplicas || `0`
    ...    available_replicas__raise_issue_if_lt=1
    ...    set_issue_details=No ready/available statefulset pods found, check events, namespace events, helm charts or kustomization objects. 
    ...    assign_stdout_from_var=available_replicas
    ${desired_replicas}=    RW.CLI.Parse Cli Json Output
    ...    rsp=${statefulset}
    ...    extract_path_to_var__desired_replicas=status.replicas || `0`
    ...    desired_replicas__raise_issue_if_lt=1
    ...    set_issue_details=No statefulset pods desired, check if the statefulset has been scaled down. 
    ...    assign_stdout_from_var=desired_replicas
    RW.CLI.Parse Cli Json Output
    ...    rsp=${desired_replicas}
    ...    extract_path_to_var__desired_replicas=@
    ...    desired_replicas__raise_issue_if_neq=${available_replicas.stdout}
    ...    set_issue_details=Desired replicas for statefulset does not match available/ready, check namespace and statefulset events, check node events or scaling events. 
    ${desired_replicas}=    Convert To Number    ${desired_replicas.stdout}
    ${available_replicas}=    Convert To Number    ${available_replicas.stdout}
    RW.Core.Add Pre To Report    StatefulSet State:\n${StatefulSet}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}

Query The Jenkins Kubernetes Workload HTTP Endpoint
    [Documentation]    Performs a curl within the jenkins statefulset kubernetes workload to determine if the pod is up and healthy, and can serve requests.
    [Tags]    HTTP    Curl    Web    Code    OK    Available    Jenkins    HTTP    Endpoint    API
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} exec statefulset/${STATEFULSET_NAME} --context=${CONTEXT} -n ${NAMESPACE} -- curl -s -o /dev/null -w "%\{http_code\}" localhost:8080/login
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${rsp}
    ...    set_severity_level=2
    ...    set_issue_expected=The jenkins login page should be available and return a 200
    ...    set_issue_actual=The jenkins login page returned a non-200 response
    ...    set_issue_title=Jenkins HTTP Check Failed
    ...    set_issue_details=Check if the statefulset is unhealthy since the non-200 HTTP code was returned from within the pod workload. 
    ...    _line__raise_issue_if_ncontains=200
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} exec statefulset/${STATEFULSET_NAME} --context=${CONTEXT} -n ${NAMESPACE} -- curl -s localhost:8080/api/json?pretty=true --user $${JENKINS_SA_USERNAME.key}:$${JENKINS_SA_TOKEN.key}
    ...    secret__jenkins_sa_username=${JENKINS_SA_USERNAME}
    ...    secret__jenkins_sa_token=${JENKINS_SA_TOKEN}
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.Core.Add Pre To Report    Remote API Info:\n${rsp.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}


Query For Stuck Jenkins Jobs
    [Documentation]    Performs a curl within the jenkins statefulset kubernetes workload to check for stuck jobs in the jenkins piepline queue.
    [Tags]    HTTP    Curl    Web    Code    OK    Available    Queue    Stuck    Jobs    Jenkins
    ${rsp}=    RW.CLI.Run Cli
    ...    cmd=${KUBERNETES_DISTRIBUTION_BINARY} exec statefulset/${STATEFULSET_NAME} --context=${CONTEXT} -n ${NAMESPACE} -- curl -s localhost:8080/queue/api/json --user $${JENKINS_SA_USERNAME.key}:$${JENKINS_SA_TOKEN.key} | jq -r '.items[] | select((.stuck == true) or (.blocked == true)) | "Why: " + .why + "\nBlocked: " + (.blocked|tostring) + "\nStuck: " + (.stuck|tostring)'
    ...    secret__jenkins_sa_username=${JENKINS_SA_USERNAME}
    ...    secret__jenkins_sa_token=${JENKINS_SA_TOKEN}
    ...    render_in_commandlist=true
    ...    env=${env}
    ...    target_service=${kubectl}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${rsp}
    ...    set_severity_level=2
    ...    set_issue_expected=The Jenkins pipeline should not have any stuck jobs
    ...    set_issue_actual=The Jenkins pipeline has stuck jobs in the queue
    ...    set_issue_title=Stuck Jobs in Jenkins Pipeline
    ...    set_issue_details=We found stuck jobs in the stdout: {_stdout} - check the jenkins console for further details on how to unstuck them.
    ...    _line__raise_issue_if_contains=Stuck
    RW.Core.Add Pre To Report    Queue Information:\n${rsp.stdout}
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}