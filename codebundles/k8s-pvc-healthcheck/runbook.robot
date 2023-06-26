*** Settings ***
Documentation       This taskset collects information about storage such as PersistentVolumes and PersistentVolumeClaims to
...                 validate health or help troubleshoot potential storage issues.
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes Persistent Volume Healthcheck
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             DateTime
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Fetch Events for Unhealthy Kubernetes PersistentVolumeClaims
    [Documentation]    Lists events related to PersistentVolumeClaims within the namespace that are not bound to PersistentVolumes.
    [Tags]    pvc    list    kubernetes    storage    persistentvolumeclaim    persistentvolumeclaims events
    ${unbound_pvc_events}=    RW.CLI.Run Cli
    ...    cmd=for pvc in $(${KUBERNETES_DISTRIBUTION_BINARY} get pvc -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.items[] | select(.status.phase != "Bound") | .metadata.name'); do ${KUBERNETES_DISTRIBUTION_BINARY} get events -n ${NAMESPACE} --context ${CONTEXT} --field-selector involvedObject.name=$pvc -o json | jq '.items[]| "Last Timestamp: " + .lastTimestamp + " Name: " + .involvedObject.name + " Message: " + .message'; done
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${regexp}=    Catenate
    ...    (?m)(?P<line>.+)
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${unbound_pvc_events}
    ...    lines_like_regexp=${regexp}
    ...    set_severity_level=1
    ...    set_issue_expected=PVCs should be bound
    ...    set_issue_actual=PVCs found pending with the following events
    ...    set_issue_title=PVC Errors & Events In Namespace ${NAMESPACE}
    ...    set_issue_details=We found "$line" in the namespace ${NAMESPACE}\nReview list of unbound PersistentVolumeClaims - check node events, application configurations, StorageClasses and CSI drivers.
    ...    line__raise_issue_if_contains=Name
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of events for unbound pvc in ${NAMESPACE}:
    RW.Core.Add Pre To Report    ${unbound_pvc_events.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

List PersistentVolumes in Terminating State
    [Documentation]    Lists events related to persistent volumes in Terminating state.
    [Tags]    pv    list    kubernetes    storage    persistentvolume    terminating    events
    ${dangline_pvcs}=    RW.CLI.Run Cli
    ...    cmd=for pv in $(${KUBERNETES_DISTRIBUTION_BINARY} get pv --context ${CONTEXT} -o json | jq -r '.items[] | select(.status.phase == "Terminating") | .metadata.name'); do ${KUBERNETES_DISTRIBUTION_BINARY} get events --all-namespaces --field-selector involvedObject.name=$pv --context ${CONTEXT} -o json | jq '.items[]| "Last Timestamp: " + .lastTimestamp + " Name: " + .involvedObject.name + " Message: " + .message'; done
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${regexp}=    Catenate
    ...    (?m)(?P<line>.+)
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${dangline_pvcs}
    ...    lines_like_regexp=${regexp}
    ...    set_severity_level=4
    ...    set_issue_expected=PV should not be stuck terminating.
    ...    set_issue_actual=PV is in a terminating state.
    ...    set_issue_title=PV Events While Terminating In Namespace ${NAMESPACE}
    ...    set_issue_details=We found "$_line" in the namespace ${NAMESPACE}\nCheck the status of terminating PersistentVolumeClaims over the next few minutes, they should disappear. If not, check that deployments or statefulsets attached to the PersistentVolumeClaims are scaled down and pods attached to the PersistentVolumeClaims are not running.
    ...    _line__raise_issue_if_contains=Name
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of events for dangling persistent volumes:
    RW.Core.Add Pre To Report    ${dangline_pvcs.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

List Pods with Attached Volumes and Related PersistentVolume Details
    [Documentation]    For each pod in a namespace, collect details on configured PersistentVolumeClaim, PersistentVolume, and node.
    [Tags]    pod    storage    pvc    pv    status    csi    storagereport
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

Fetch the Storage Utilization for PVC Mounts
    [Documentation]    For each pod in a namespace, fetch the utilization of any PersistentVolumeClaims mounted using the linux df command. Requires kubectl exec permissions.
    [Tags]    pod    storage    pvc    utilization    capacity    persistentvolumeclaims    persistentvolumeclaim
    ${pod_pvc_utilization}=    RW.CLI.Run Cli
    ...    cmd=for pod in $(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n ${NAMESPACE} --field-selector=status.phase=Running --context ${CONTEXT} -o jsonpath='{range .items[*]}{.metadata.name}{"\\n"}{end}'); do for pvc in $(${KUBERNETES_DISTRIBUTION_BINARY} get pods $pod -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{range .spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\\n"}{end}'); do for volumeName in $(${KUBERNETES_DISTRIBUTION_BINARY} get pod $pod -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.spec.volumes[] | select(has("persistentVolumeClaim")) | .name'); do mountPath=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $pod -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r --arg vol "$volumeName" '.spec.containers[].volumeMounts[] | select(.name == $vol) | .mountPath'); containerName=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $pod -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r --arg vol "$volumeName" '.spec.containers[] | select(.volumeMounts[].name == $vol) | .name'); echo -e "\\n---\\nPod: $pod, PVC: $pvc, volumeName: $volumeName, containerName: $containerName, mountPath: $mountPath"; ${KUBERNETES_DISTRIBUTION_BINARY} exec $pod -n ${NAMESPACE} --context ${CONTEXT} -c $containerName -- df -h $mountPath; done; done; done;
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${regexp}=    Evaluate    r'.*\\s(?P<pvc_utilization>\\d+)%'
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${pod_pvc_utilization}
    ...    lines_like_regexp=${regexp}
    ...    set_severity_level=2
    ...    set_issue_expected=PVC should be less than 95% utilized.
    ...    set_issue_actual=PVC is 95% or greater.
    ...    set_issue_title=PVC Storage Utilization As Report by Pod
    ...    set_issue_details=Found PVC Utilization of: $pvc_utilization in namespace ${NAMESPACE}\nReview PersistentVolumeClaims utilization above 95% as they will be at or nearing capacity. Expand PersistentVolumeClaims, PersistentVolumes, remove uneeded storage, or check application configuration such as database logs and backup jobs.
    ...    pvc_utilization__raise_issue_if_gt=95
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of PVC storage mount utilization in ${NAMESPACE}:
    RW.Core.Add Pre To Report    ${pod_pvc_utilization.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}


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
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
