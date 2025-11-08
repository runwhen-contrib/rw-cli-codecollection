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
    [Tags]    access:read-only    pvc    list    kubernetes    storage    persistentvolumeclaim    persistentvolumeclaims    events
    ${unbound_pvc_events}=    RW.CLI.Run Cli
    ...    cmd=for pvc in $(${KUBERNETES_DISTRIBUTION_BINARY} get pvc -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.items[] | select(.status.phase != "Bound") | .metadata.name'); do ${KUBERNETES_DISTRIBUTION_BINARY} get events -n ${NAMESPACE} --context ${CONTEXT} --field-selector involvedObject.name=$pvc -o json | jq '.items[]| "Last Timestamp: " + .lastTimestamp + ", Name: " + .involvedObject.name + ", Message: " + .message'; done
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
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
    ...    render_in_commandlist=true
    # Check if any PVCs are stuck terminating
    ${contains_terminating}=    Run Keyword And Return Status    Should Contain    ${terminating_pvcs.stdout}    Terminating
    IF    ${contains_terminating}
        @{pvc_names_list}=    Get Regexp Matches    ${terminating_pvcs.stdout}    (?m)^([^ ]+)
        ${pvc_names}=    Catenate    SEPARATOR=,     @{pvc_names_list}
        
        @{finalizers_list}=    Get Regexp Matches    ${terminating_pvcs.stdout}    "([^"]+)"
        ${finalizers}=    Catenate    SEPARATOR=,     @{finalizers_list}
        ${finalizers_count}=    Get Length    ${finalizers_list}
        ${finalizer_phrase}=    Set Variable If    ${finalizers_count} > 0    with the finalizer(s) `${finalizers}`    ${EMPTY}
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=PersistentVolumeClaims should not be stuck terminating
        ...    actual=PersistentVolumeClaims are in a terminating state and might be stuck
        ...    reproduce_hint=${terminating_pvcs.cmd}
        ...    title=PersistentVolumeClaims Found Terminating In Namespace `${NAMESPACE}`
        ...    details=We found "${terminating_pvcs.stdout}" in the namespace `${NAMESPACE}`\nCheck the status of terminating PersistentVolumeClaims over the next few minutes, as they should disappear. If not, check that deployments or statefulsets attached to the PersistentVolumeClaims are scaled down and pods attached to the PersistentVolumeClaims are not running.
        ...    next_steps=Escalate PersistentVolumeClaims stuck terminating for namespace `${NAMESPACE}`
        ...    summary=PersistentVolumeClaims `${pvc_names}` in namespace `${NAMESPACE}` found in a Terminating state ${finalizer_phrase}. This indicates that resources linked to the claim(s) may still be active, preventing its deletion. The volume should be monitored to confirm it completes termination; if it remains stuck, investigate finalizers, verify that all related pods and StatefulSets are stopped, and review deletion and garbage collection logs.
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of events for dangling persistent volumes:
    RW.Core.Add Pre To Report    ${terminating_pvcs.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}


List PersistentVolumes in Terminating State in Namespace `${NAMESPACE}`
    [Documentation]    Lists events related to persistent volumes in Terminating state.
    [Tags]    access:read-only    pv    list    kubernetes    storage    persistentvolume    terminating    events
    ${dangling_pvs}=    RW.CLI.Run Cli
    ...    cmd=for pv in $(${KUBERNETES_DISTRIBUTION_BINARY} get pv --context ${CONTEXT} -o json | jq -r '.items[] | select(.status.phase == "Terminating") | .metadata.name'); do ${KUBERNETES_DISTRIBUTION_BINARY} get events --all-namespaces --field-selector involvedObject.name=$pv --context ${CONTEXT} -o json | jq '.items[]| "Last Timestamp: " + .lastTimestamp + " Name: " + .involvedObject.name + " Message: " + .message'; done
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true    
    # Check if any PVs are stuck terminating
    ${contains_name}=    Run Keyword And Return Status    Should Contain    ${dangling_pvs.stdout}    Name
    IF    ${contains_name}    
        # Extract all PV names
        ${pv_names}=    Get Regexp Matches    ${dangling_pvs.stdout}    (?m)Name:\s*([^\s]+)
        ${pv_names}=    Evaluate    [item.replace('Name: ', '').replace(' Me', '').strip() for item in $pv_names]
        ${pv_names}=    Catenate    SEPARATOR=,     @{pv_names}

        RW.Core.Add Issue
        ...    severity=4
        ...    expected=PersistentVolumes should not be stuck terminating
        ...    actual=PersistentVolumes are in a terminating state and might be stuck
        ...    title=PersistentVolumes Found Terminating In Namespace `${NAMESPACE}`
        ...    details=We found "${dangling_pvs.stdout}" in the namespace `${NAMESPACE}`\nCheck the status of terminating PersistentVolumes over the next few minutes, as they should disappear. If not, check that deployments or statefulsets attached to the related PersistentVolumeClaims are scaled down and pods attached to the PersistentVolumeClaims are not running.
        ...    reproduce_hint=Check PersistentVolume events and termination status
        ...    next_steps=Escalate PersistentVolumes stuck terminating for namespace `${NAMESPACE}`
        ...    summary=PersistentVolume `${pv_names}` in the `${NAMESPACE}` namespace was found stuck in a terminating state due to finalizers preventing deletion. Normally, these volumes should be removed automatically once no longer in use. Further action is needed to ensure associated deployments or StatefulSets are scaled down and to investigate finalizers or controller issues preventing cleanup.
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of events for dangling persistent volumes:
    RW.Core.Add Pre To Report    ${dangling_pvs.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

List Pods with Attached Volumes and Related PersistentVolume Details in Namespace `${NAMESPACE}`
    [Documentation]    For each pod in a namespace, collect details on configured PersistentVolumeClaim, PersistentVolume, and node.
    [Tags]    access:read-only     pod    storage    pvc    pv    status    csi    storagereport
    ${pod_storage_report}=    RW.CLI.Run Cli
    ...    cmd=for pod in $(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n ${NAMESPACE} --field-selector=status.phase=Running --context ${CONTEXT} -o jsonpath='{range .items[*]}{.metadata.name}{"\\n"}{end}'); do for pvc in $(${KUBERNETES_DISTRIBUTION_BINARY} get pods $pod -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{range .spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\\n"}{end}'); do pv=$(${KUBERNETES_DISTRIBUTION_BINARY} get pvc $pvc -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.volumeName}') && status=$(${KUBERNETES_DISTRIBUTION_BINARY} get pv $pv --context ${CONTEXT} -o jsonpath='{.status.phase}') && node=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $pod -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.nodeName}') && zone=$(${KUBERNETES_DISTRIBUTION_BINARY} get nodes $node --context ${CONTEXT} -o jsonpath='{.metadata.labels.topology\\.kubernetes\\.io/zone}') && ingressclass=$(${KUBERNETES_DISTRIBUTION_BINARY} get pvc $pvc -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.spec.storageClassName}') && accessmode=$(${KUBERNETES_DISTRIBUTION_BINARY} get pvc $pvc -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{.status.accessModes[0]}') && reclaimpolicy=$(${KUBERNETES_DISTRIBUTION_BINARY} get pv $pv --context ${CONTEXT} -o jsonpath='{.spec.persistentVolumeReclaimPolicy}') && csidriver=$(${KUBERNETES_DISTRIBUTION_BINARY} get pv $pv --context ${CONTEXT} -o jsonpath='{.spec.csi.driver}')&& echo -e "\\n------------\\nPod: $pod\\nPVC: $pvc\\nPV: $pv\\nStatus: $status\\nNode: $node\\nZone: $zone\\nIngressClass: $ingressclass\\nAccessModes: $accessmode\\nReclaimPolicy: $reclaimpolicy\\nCSIDriver: $csidriver\\n"; done; done
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of configured persistent volumes in ${NAMESPACE}:
    RW.Core.Add Pre To Report    ${pod_storage_report.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Fetch the Storage Utilization for PVC Mounts in Namespace `${NAMESPACE}`
    [Documentation]    For each pod in a namespace, fetch the utilization of any PersistentVolumeClaims mounted using the linux df command. Requires kubectl exec permissions.
    [Tags]    access:read-only    pod    storage    pvc    utilization    capacity    persistentvolumeclaims    persistentvolumeclaim    check pvc
    ${pod_pvc_utilization}=    RW.CLI.Run Cli
    ...    cmd=for pod in $(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n ${NAMESPACE} --field-selector=status.phase=Running --context ${CONTEXT} -o jsonpath='{range .items[*]}{.metadata.name}{"\\n"}{end}'); do for pvc in $(${KUBERNETES_DISTRIBUTION_BINARY} get pods $pod -n ${NAMESPACE} --context ${CONTEXT} -o jsonpath='{range .spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\\n"}{end}'); do for volumeName in $(${KUBERNETES_DISTRIBUTION_BINARY} get pod $pod -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.spec.volumes[] | select(has("persistentVolumeClaim")) | .name'); do mountPath=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $pod -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r --arg vol "$volumeName" '.spec.containers[].volumeMounts[] | select(.name == $vol) | .mountPath'); containerName=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $pod -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r --arg vol "$volumeName" '.spec.containers[] | select(.volumeMounts[].name == $vol) | .name'); echo -e "\\n------------\\nPod: $pod, PVC: $pvc, volumeName: $volumeName, containerName: $containerName, mountPath: $mountPath"; ${KUBERNETES_DISTRIBUTION_BINARY} exec $pod -n ${NAMESPACE} --context ${CONTEXT} -c $containerName -- df -h $mountPath; done; done; done;
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    ${pvc_utilization_script}=    RW.CLI.Run Bash File
    ...    bash_file=pvc_utilization_check.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ${pvc_recommendations}=    RW.CLI.Run Cli
    ...    cmd=cat pvc_issues.json
    ...    env=${env}
    ...    include_in_history=false
    ${issue_list}=    Evaluate    json.loads(r'''${pvc_recommendations.stdout}''')    json
    IF    len(@{issue_list}) > 0
        FOR    ${item}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${item["severity"]}
            ...    expected=PVCs are healthy and have free space in Namespace `${NAMESPACE}`
            ...    actual=PVC issues exist in Namespace `${NAMESPACE}`
            ...    title=${item["title"]} in `${NAMESPACE}`
            ...    reproduce_hint=${pod_pvc_utilization.cmd}
            ...    details=${item}
            ...    next_steps=${item["next_steps"]}
            ...    summary=${item["summary"]}
            ...    observations=${item["observations"]}
        END
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Summary of PVC storage mount utilization in ${NAMESPACE}:
    RW.Core.Add Pre To Report    ${pod_pvc_utilization.stdout}
    RW.Core.Add Pre To Report    Commands Used:\n${history}

Check for RWO Persistent Volume Node Attachment Issues in Namespace `${NAMESPACE}`
    [Documentation]    For each pod in a namespace, check if it has an RWO persistent volume claim and if so, validate that the pod and the pv are on the same node. 
    [Tags]    access:read-only    pod    storage    pvc    readwriteonce    node    persistentvolumeclaims    persistentvolumeclaim    scheduled   attachment
    ${pod_rwo_node_and_pod_attachment}=    RW.CLI.Run Cli
    ...    cmd=NAMESPACE="${NAMESPACE}"; CONTEXT="${CONTEXT}"; PODS=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n $NAMESPACE --context=$CONTEXT -o json); for pod in $(jq -r '.items[] | @base64' <<< "$PODS"); do _jq() { jq -r \${1} <<< "$(base64 --decode <<< \${pod})"; }; POD_NAME=$(_jq '.metadata.name'); [[ "$(_jq '.metadata.ownerReferences[0].kind')" == "Job" ]] && continue; POD_NODE_NAME=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $POD_NAME -n $NAMESPACE --context=$CONTEXT -o custom-columns=:.spec.nodeName --no-headers); PVC_NAMES=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $POD_NAME -n $NAMESPACE --context=$CONTEXT -o jsonpath='{.spec.volumes[*].persistentVolumeClaim.claimName}'); for pvc_name in $PVC_NAMES; do PVC=$(${KUBERNETES_DISTRIBUTION_BINARY} get pvc $pvc_name -n $NAMESPACE --context=$CONTEXT -o json); ACCESS_MODE=$(jq -r '.spec.accessModes[0]' <<< "$PVC"); if [[ "$ACCESS_MODE" == "ReadWriteOnce" ]]; then PV_NAME=$(jq -r '.spec.volumeName' <<< "$PVC"); STORAGE_NODE_NAME=$(jq -r --arg pv "$PV_NAME" '.items[] | select(.status.volumesAttached != null) | select(.status.volumesInUse[] | contains($pv)) | .metadata.name' <<< "$(${KUBERNETES_DISTRIBUTION_BINARY} get nodes --context=$CONTEXT -o json)"); echo "------------"; if [[ "$POD_NODE_NAME" == "$STORAGE_NODE_NAME" ]]; then echo "OK: Pod and Storage Node Matched"; else echo "Error: Pod and Storage Node Mismatched - If the issue persists, the node requires attention."; fi; echo "Pod: $POD_NAME"; echo "PVC: $pvc_name"; echo "PV: $PV_NAME"; echo "Node with Pod: $POD_NODE_NAME"; echo "Node with Storage: $STORAGE_NODE_NAME"; echo; fi; done; done
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true
    ...    render_in_commandlist=true
    # Check if any RWO storage scheduling errors are found
    ${contains_error}=    Run Keyword And Return Status    Should Contain    ${pod_rwo_node_and_pod_attachment.stdout}    Error
    IF    ${contains_error}
        RW.Core.Add Issue
        ...    severity=2
        ...    expected=All pods with RWO storage must be scheduled on the same node in which the persistent volume is attached in namespace `${NAMESPACE}`
        ...    actual=Pods with RWO found on a different node than their RWO storage in namespace `${NAMESPACE}`
        ...    title=Pods with RWO Storage Have Scheduling Issues in Namespace `${NAMESPACE}`
        ...    details=All Pods and RWO their storage details are:\n\n${pod_rwo_node_and_pod_attachment.stdout}\n\n
        ...    reproduce_hint=Check pod and PV node scheduling and attachment status
        ...    next_steps=Escalate storage attach issues to service owner for namespace `${NAMESPACE}`
    END
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
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}", "NAMESPACE":"${NAMESPACE}"}
