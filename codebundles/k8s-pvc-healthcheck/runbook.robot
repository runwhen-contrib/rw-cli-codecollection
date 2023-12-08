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
Library             String

Suite Setup         Suite Initialization


*** Tasks ***
Fetch Events for Unhealthy Kubernetes PersistentVolumeClaims in Namespace `${NAMESPACE}`
    [Documentation]    Lists events related to PersistentVolumeClaims within the namespace that are not bound to PersistentVolumes.
    [Tags]    pvc    list    kubernetes    storage    persistentvolumeclaim    persistentvolumeclaims    events    ${NAMESPACE}
    ${unbound_pvc_events}=    RW.CLI.Run Cli
    ...    cmd=for pvc in $(${KUBERNETES_DISTRIBUTION_BINARY} get pvc -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.items[] | select(.status.phase != "Bound") | .metadata.name'); do ${KUBERNETES_DISTRIBUTION_BINARY} get events -n ${NAMESPACE} --context ${CONTEXT} --field-selector involvedObject.name=$pvc -o json | jq '.items[]| "Last Timestamp: " + .lastTimestamp + ", Name: " + .involvedObject.name + ", Message: " + .message'; done
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ${unbound_pvc_event_list}=    Split String  ${unbound_pvc_events.stdout}    \n
    @{next_steps}=     Create List
    IF    len($unbound_pvc_event_list) > 0
        FOR    ${item}    IN    @{unbound_pvc_event_list}
            ${is_not_just_newline}=    Evaluate    '''${item}'''.strip() != ''
            IF    ${is_not_just_newline}  
                ${pvc}=    RW.CLI.Run Cli
                ...    cmd=echo "${item}" | awk -F', ' '{split($2,a,": "); print a[2]}' | sed 's/ *$//' | tr -d '\n'
                ...    env=${env}
                ...    secret_file__kubeconfig=${kubeconfig}
                ...    include_in_history=false
                ${message}=    RW.CLI.Run Cli
                ...    cmd=echo "${item}" | awk -F', ' '{split($3,a,": "); print a[2]}' | sed 's/ *$//' | tr -d '\n'
                ...    env=${env}
                ...    secret_file__kubeconfig=${kubeconfig}
                ...    include_in_history=false
                ${message}=    Replace String    ${message.stdout}    "    ${EMPTY}
                ${item_next_steps}=    RW.CLI.Run Bash File
                ...    bash_file=storage_next_steps.sh
                ...    cmd_override=./storage_next_steps.sh "${message}" "PersistentVolumeClaim" "${pvc.stdout}"
                ...    env=${env}
                ...    secret_file__kubeconfig=${kubeconfig}
                ...    include_in_history=False
                Append To List    ${next_steps}    "${item_next_steps.stdout}" 
            END
        END
    END 
    IF    len($next_steps) > 0
        ${next_steps_string}=    Catenate    SEPARATOR=\n    @{next_steps} 
        ${next_steps_string}=    Replace String    ${next_steps_string}    "    ${EMPTY}
        ${next_steps_string}=    Replace String    ${next_steps_string}    ,    ${EMPTY}

        RW.Core.Add Issue
        ...    severity=2
        ...    expected=PVCs should be bound in Namespace `${NAMESPACE}`
        ...    actual=Unbound PVCs found in Namespace `${NAMESPACE}`
        ...    title=Unbound PVCs found in Namespace `${NAMESPACE}`
        ...    reproduce_hint=${unbound_pvc_events.cmd}
        ...    details=Unbound PVC events are:\n${unbound_pvc_events.stdout}
        ...    next_steps=${next_steps_string}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of events for unbound pvc in ${NAMESPACE}:
    RW.Core.Add Pre To Report    ${unbound_pvc_events.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

List PersistentVolumeClaims in Terminating State in Namespace `${NAMESPACE}`
    [Documentation]    Lists persistentvolumeclaims in a Terminating state.
    [Tags]    pvc    list    kubernetes    storage    persistentvolumeclaim    terminating        check PersistentVolumes
    ${terminating_pvcs}=    RW.CLI.Run Cli
    ...    cmd=namespace=${NAMESPACE}; context=${CONTEXT}; ${KUBERNETES_DISTRIBUTION_BINARY} get pvc -n $namespace --context=$context -o json | jq -r '.items[] | select(.metadata.deletionTimestamp != null) | .metadata.name as $name | .metadata.deletionTimestamp as $deletion_time | .metadata.finalizers as $finalizers | "\\($name) is in Terminating state (Deletion started at: \\($deletion_time)). Finalizers: \\($finalizers)"'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${terminating_pvcs}
    ...    set_severity_level=4
    ...    set_issue_expected=PersistentVolumeClaims should not be stuck terminating.
    ...    set_issue_actual=PersistentVolumeClaims are in a terminating state and might be stuck.
    ...    set_issue_reproduce_hint=${terminating_pvcs.cmd}
    ...    set_issue_title=PersistentVolumeClaims Found Terminating In Namespace `${NAMESPACE}`
    ...    set_issue_details=We found "$_line" in the namespace `${NAMESPACE}`\nCheck the status of terminating PersistentVolumeClaims over the next few minutes, as they should disappear. If not, check that deployments or statefulsets attached to the PersistentVolumeClaims are scaled down and pods attached to the PersistentVolumeClaims are not running.
    ...    _line__raise_issue_if_contains=Terminating
    ...    set_next_steps=Escalate PersistentVolumeClaims stuck terminating for namespace `${NAMESPACE}`
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of events for dangling persistent volumes:
    RW.Core.Add Pre To Report    ${terminating_pvcs.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}


List PersistentVolumes in Terminating State in Namespace `${NAMESPACE}`
    [Documentation]    Lists events related to persistent volumes in Terminating state.
    [Tags]    pv    list    kubernetes    storage    persistentvolume    terminating    events    ${NAMESPACE}
    ${dangling_pvs}=    RW.CLI.Run Cli
    ...    cmd=for pv in $(${KUBERNETES_DISTRIBUTION_BINARY} get pv --context ${CONTEXT} -o json | jq -r '.items[] | select(.status.phase == "Terminating") | .metadata.name'); do ${KUBERNETES_DISTRIBUTION_BINARY} get events --all-namespaces --field-selector involvedObject.name=$pv --context ${CONTEXT} -o json | jq '.items[]| "Last Timestamp: " + .lastTimestamp + " Name: " + .involvedObject.name + " Message: " + .message'; done
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${dangling_pvs}
    ...    set_severity_level=4
    ...    set_issue_expected=PersistentVolumes should not be stuck terminating.
    ...    set_issue_actual=PersistentVolumes are in a terminating state and might be stuck.
    ...    set_issue_title=PersistentVolumes Found Terminating In Namespace `${NAMESPACE}`
    ...    set_issue_details=We found "$_line" in the namespace `${NAMESPACE}`\nCheck the status of terminating PersistentVolumes over the next few minutes, as they should disappear. If not, check that deployments or statefulsets attached to the related PersistentVolumeClaims are scaled down and pods attached to the PersistentVolumeClaims are not running.
    ...    _line__raise_issue_if_contains=Name
    ...    set_next_steps=Escalate PersistentVolumes stuck terminating for namespace `${NAMESPACE}`
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of events for dangling persistent volumes:
    RW.Core.Add Pre To Report    ${dangling_pvs.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

List Pods with Attached Volumes and Related PersistentVolume Details in Namespace `${NAMESPACE}`
    [Documentation]    For each pod in a namespace, collect details on configured PersistentVolumeClaim, PersistentVolume, and node.
    [Tags]    pod    storage    pvc    pv    status    csi    storagereport    ${NAMESPACE}
    ${pod_storage_report}=    RW.CLI.Run Cli
    ...    cmd=for pod in $(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n ${NAMESPACE} --field-selector=status.phase=Running --context ${CONTEXT} -o jsonpath='{range .items[*]}{.metadata.name}{"\\n"}{end}'); do for pvc in $(${KUBERNETES_DISTRIBUTION_BINARY} get pods $pod -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{range .spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\\n"}{end}'); do pv=$(${KUBERNETES_DISTRIBUTION_BINARY} get pvc $pvc -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.volumeName}') && status=$(${KUBERNETES_DISTRIBUTION_BINARY} get pv $pv --context ${CONTEXT} -o jsonpath='{.status.phase}') && node=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $pod -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.nodeName}') && zone=$(${KUBERNETES_DISTRIBUTION_BINARY} get nodes $node --context ${CONTEXT} -o jsonpath='{.metadata.labels.topology\\.kubernetes\\.io/zone}') && ingressclass=$(${KUBERNETES_DISTRIBUTION_BINARY} get pvc $pvc -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.storageClassName}') && accessmode=$(${KUBERNETES_DISTRIBUTION_BINARY} get pvc $pvc -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.status.accessModes[0]}') && reclaimpolicy=$(${KUBERNETES_DISTRIBUTION_BINARY} get pv $pv --context ${CONTEXT} -o jsonpath='{.spec.persistentVolumeReclaimPolicy}') && csidriver=$(${KUBERNETES_DISTRIBUTION_BINARY} get pv $pv --context ${CONTEXT} -o jsonpath='{.spec.csi.driver}')&& echo -e "\\n------------\\nPod: $pod\\nPVC: $pvc\\nPV: $pv\\nStatus: $status\\nNode: $node\\nZone: $zone\\nIngressClass: $ingressclass\\nAccessModes: $accessmode\\nReclaimPolicy: $reclaimpolicy\\nCSIDriver: $csidriver\\n"; done; done
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of configured persistent volumes in ${NAMESPACE}:
    RW.Core.Add Pre To Report    ${pod_storage_report.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Fetch the Storage Utilization for PVC Mounts in Namespace `${NAMESPACE}`
    [Documentation]    For each pod in a namespace, fetch the utilization of any PersistentVolumeClaims mounted using the linux df command. Requires kubectl exec permissions.
    [Tags]    pod    storage    pvc    utilization    capacity    persistentvolumeclaims    persistentvolumeclaim    check pvc    ${NAMESPACE}
    ${pod_pvc_utilization}=    RW.CLI.Run Cli
    ...    cmd=for pod in $(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n ${NAMESPACE} --field-selector=status.phase=Running --context ${CONTEXT} -o jsonpath='{range .items[*]}{.metadata.name}{"\\n"}{end}'); do for pvc in $(${KUBERNETES_DISTRIBUTION_BINARY} get pods $pod -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{range .spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\\n"}{end}'); do for volumeName in $(${KUBERNETES_DISTRIBUTION_BINARY} get pod $pod -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.spec.volumes[] | select(has("persistentVolumeClaim")) | .name'); do mountPath=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $pod -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r --arg vol "$volumeName" '.spec.containers[].volumeMounts[] | select(.name == $vol) | .mountPath'); containerName=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $pod -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r --arg vol "$volumeName" '.spec.containers[] | select(.volumeMounts[].name == $vol) | .name'); echo -e "\\n------------\\nPod: $pod, PVC: $pvc, volumeName: $volumeName, containerName: $containerName, mountPath: $mountPath"; ${KUBERNETES_DISTRIBUTION_BINARY} exec $pod -n ${NAMESPACE} --context ${CONTEXT} -c $containerName -- df -h $mountPath; done; done; done;
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ${unhealthy_volume_capacity}=    RW.CLI.Run Cli
    ...    cmd=echo "${pod_pvc_utilization.stdout}" | awk '/------------/ { if (flag) { print record "\\n" $0; } record = ""; flag = 0; next; } $5 ~ /[9][5-9]%/ || $5 == "100%" { flag = 1; } { if (record == "") { record = $0; } else { record = record "\\n" $0; } } END { if (flag) { print record; } }'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    include_in_history=false
    @{next_steps}=     Create List
    ${unhealthy_volume_list}=    Split String  ${unhealthy_volume_capacity.stdout}    ------------
    IF    len($unhealthy_volume_list) > 0
        FOR    ${item}    IN    @{unhealthy_volume_list}
            ${is_not_just_newline}=    Evaluate    '''${item}'''.strip() != ''
            IF    ${is_not_just_newline}  
                ${pvc}=    RW.CLI.Run Cli
                ...    cmd=echo "${item}" | grep PVC | awk -F', ' '{split($2,a,": "); print a[2]}' | sed 's/ *$//' | tr -d '\n'
                ...    env=${env}
                ...    secret_file__kubeconfig=${kubeconfig}
                ...    include_in_history=false
                Append To List    ${next_steps}    "Expand Persistent Volume Claim in namespace `${NAMESPACE}`: `${pvc.stdout}`" 
            END
        END
    END
    IF    len($next_steps) > 0
        ${next_steps_string}=    Catenate    SEPARATOR=\n    @{next_steps} 
        ${next_steps_string}=    Replace String    ${next_steps_string}    "    ${EMPTY}
        ${next_steps_string}=    Replace String    ${next_steps_string}    ,    ${EMPTY}

        RW.Core.Add Issue
        ...    severity=2
        ...    expected=PVCs should be less than 95% utilized for Namespace `${NAMESPACE}`
        ...    actual=PVC utilization is 95% or greater in Namespace `${NAMESPACE}`
        ...    title=PVC Storage Utilization Issues in Namespace `${NAMESPACE}`
        ...    reproduce_hint=${pod_pvc_utilization.cmd}
        ...    details=Found excessive PVC utilization for:\n${unhealthy_volume_capacity.stdout}
        ...    next_steps=${next_steps_string}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of PVC storage mount utilization in ${NAMESPACE}:
    RW.Core.Add Pre To Report    ${pod_pvc_utilization.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Check for RWO Persistent Volume Node Attachment Issues in Namespace `${NAMESPACE}`
    [Documentation]    For each pod in a namespace, check if it has an RWO persistent volume claim and if so, validate that the pod and the pv are on the same node. 
    [Tags]    pod    storage    pvc    readwriteonce    node    persistentvolumeclaims    persistentvolumeclaim    scheduled   attachment    ${NAMESPACE}
    ${pod_rwo_node_and_pod_attachment}=    RW.CLI.Run Cli
    ...    cmd=NAMESPACE="${NAMESPACE}"; CONTEXT="${CONTEXT}"; PODS=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n $NAMESPACE --context=$CONTEXT -o json); for pod in $(jq -r '.items[] | @base64' <<< "$PODS"); do _jq() { jq -r \${1} <<< "$(base64 --decode <<< \${pod})"; }; POD_NAME=$(_jq '.metadata.name'); POD_NODE_NAME=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $POD_NAME -n $NAMESPACE --context=$CONTEXT -o custom-columns=:.spec.nodeName --no-headers); PVC_NAMES=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $POD_NAME -n $NAMESPACE --context=$CONTEXT -o jsonpath='{.spec.volumes[*].persistentVolumeClaim.claimName}'); for pvc_name in $PVC_NAMES; do PVC=$(${KUBERNETES_DISTRIBUTION_BINARY} get pvc $pvc_name -n $NAMESPACE --context=$CONTEXT -o json); ACCESS_MODE=$(jq -r '.spec.accessModes[0]' <<< "$PVC"); if [[ "$ACCESS_MODE" == "ReadWriteOnce" ]]; then PV_NAME=$(jq -r '.spec.volumeName' <<< "$PVC"); STORAGE_NODE_NAME=$(jq -r --arg pv "$PV_NAME" '.items[] | select(.status.volumesAttached != null) | select(.status.volumesInUse[] | contains($pv)) | .metadata.name' <<< "$(${KUBERNETES_DISTRIBUTION_BINARY} get nodes --context=$CONTEXT -o json)"); echo "------------"; if [[ "$POD_NODE_NAME" == "$STORAGE_NODE_NAME" ]]; then echo "OK: Pod and Storage Node Matched"; else echo "Error: Pod and Storage Node Mismatched - If the issue persists, the node requires attention."; fi; echo "Pod: $POD_NAME"; echo "PVC: $pvc_name"; echo "PV: $PV_NAME"; echo "Node with Pod: $POD_NODE_NAME"; echo "Node with Storage: $STORAGE_NODE_NAME"; echo; fi; done; done
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${pod_rwo_node_and_pod_attachment}
    ...    set_severity_level=2
    ...    set_issue_expected=All pods with RWO storage must be scheduled on the same node in which the persistent volume is attached `${NAMESPACE}`
    ...    set_issue_actual=Pods with RWO found on a different node than their RWO storage `${NAMESPACE}`
    ...    set_issue_title=Pods with RWO storage might have storage scheduling issues for namespace `${NAMESPACE}`
    ...    set_issue_details=All Pods and RWO their storage details are:\n\n$_stdout\n\n
    ...    set_issue_next_steps=Escalate storage attach issues to service owner for namespace `${NAMESPACE}`
    ...    _line__raise_issue_if_contains=Error
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of Pods with RWO storage and the nodes their scheduling details for namespace: ${NAMESPACE}:
    RW.Core.Add Pre To Report    ${pod_rwo_node_and_pod_attachment.stdout}
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
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}"}
