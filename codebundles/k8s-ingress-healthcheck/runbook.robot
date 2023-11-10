*** Settings ***
Documentation       Triages issues related to a ingress objects and services.
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes Ingress Healthcheck
Metadata            Supports    Kubernetes,AKS,EKS,GKE,OpenShift

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             String
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Fetch Ingress Object Health in Namespace 
    [Documentation]    Fetches all ingress objects in the namespace and outputs the name, health status, services, and endpoints. 
    [Tags]    service    ingress    endpoint   health 
    ${ingress_object_summary}=    RW.CLI.Run Cli
    ...    cmd=NAMESPACE="${NAMESPACE}";CONTEXT="${CONTEXT}";ingresses=$(${KUBERNETES_DISTRIBUTION_BINARY} get ingress -n "$NAMESPACE" --context "$CONTEXT" -o jsonpath='{range .items[*]}{.metadata.name}{"\\n"}{end}');for ingress in $ingresses;do echo "Ingress: $ingress";health_status="NA";backend_services=$(${KUBERNETES_DISTRIBUTION_BINARY} get ingress "$ingress" -n "$NAMESPACE" --context "$CONTEXT" -o jsonpath='{range .spec.rules[*].http.paths[*]}{.backend.service.name}{"|"}{.backend.service.port.number}{"\\n"}{end}');while IFS='|' read -r service port;do echo "Backend Service: $service, Port: $port";target_ports=$(${KUBERNETES_DISTRIBUTION_BINARY} get service "$service" -n "$NAMESPACE" --context "$CONTEXT" -o jsonpath="{.spec.ports[?(@.port==$port)].targetPort}");service_exists=$(${KUBERNETES_DISTRIBUTION_BINARY} get service "$service" -n "$NAMESPACE" --context "$CONTEXT" -ojsonpath='{.metadata.name}');if [ -z "$service_exists" ];then health_status="Unhealthy";echo "Error: Service $service does not exist";echo "Next Step: Check namespace $NAMESPACE for service name $service.";continue;else selectors=$(${KUBERNETES_DISTRIBUTION_BINARY} get svc "$service" -n "$NAMESPACE" --context "$CONTEXT" -o jsonpath='{.spec.selector}');label_selector="";for key in $(echo $selectors | jq -r 'keys[]');do value=$(echo $selectors | jq -r --arg key "$key" '.[$key]');label_selector="\${label_selector}\${key}=\${value},";done;label_selector=\${label_selector::-1};found_owner=0;for kind in deployment statefulset daemonset;do matching_owners=$(${KUBERNETES_DISTRIBUTION_BINARY} get $kind -n "$NAMESPACE" --context "$CONTEXT" -l "$label_selector" -o jsonpath='{.items[*].metadata.name}');if [ -n "$matching_owners" ];then for owner in $matching_owners;do echo "Owner Kind: $kind";echo "Owner Name: $owner";found_owner=1;done;fi;done;if [ "$found_owner" == 0 ];then echo "Error: No matching deployment, statefulset, or daemonset found";echo "Next Step: Check namespace $NAMESPACE for deployment, statefulset, or daemonset with labels that match $label_selector";fi;port_found="No";associated_pods=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" --context "$CONTEXT" -l "$label_selector" -o jsonpath='{.items[*].metadata.name}');for pod in $associated_pods;do container_ports=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod "$pod" -n "$NAMESPACE" --context "$CONTEXT" -o jsonpath='{.spec.containers[*].ports[*].containerPort}');for target_port in $target_ports;do if echo "$container_ports" | grep -wq "$target_port";then port_found="Yes";break;fi;done;done;if [ "$port_found" = "No" ];then health_status="Unhealthy";echo "Warning: targetPort $target_ports of service $service is not found as a containerPort in associated pods";else health_status="Healthy";fi;endpoint_pods=$(${KUBERNETES_DISTRIBUTION_BINARY} get endpoints "$service" -n "$NAMESPACE" --context "$CONTEXT" -ojsonpath='{range .subsets[*].addresses[*]}- Pod Name: {.targetRef.name}\\n Pod IP: {.ip}\\n{end}');if [ -z "$endpoint_pods" ];then health_status="Unhealthy";echo "Error: Endpoint for service $service does not have any pods"; echo "Next Step: Check namespace $NAMESPACE for failed pods";else echo "Endpoint Pod:";echo "$endpoint_pods";health_status="Healthy";fi;fi;done<<<"$backend_services";echo "Health Status: $health_status";echo "------------";done
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${unhealthy_objects}=    RW.CLI.Run Cli
    ...    cmd=echo "${ingress_object_summary.stdout}" | awk '/^Ingress:/ {rec=$0; next} {rec=rec ORS $0} /^Health Status: Unhealthy$/ {print rec ORS "------------"}'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${unhealthy_objects_next_steps}=    RW.CLI.Run Cli
    ...    cmd=echo "${unhealthy_objects.stdout}" | grep '^Next Step:' | sed 's/Next Step: //'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${unhealthy_objects}
    ...    set_severity_level=3
    ...    set_issue_expected=All ingress objects should have services and active endpoints in namespace: ${NAMESPACE}
    ...    set_issue_actual=Ingress objects missing services or endpoints found in namespace: ${NAMESPACE}
    ...    set_issue_title=Unhealthy ingress objects found in ${NAMESPACE}
    ...    set_issue_details=The following unhealthy objects were found:\n\n${unhealthy_objects.stdout}\n\n
    ...    set_issue_next_steps=\n\n${unhealthy_objects_next_steps.stdout}
    ...    _line__raise_issue_if_contains=Unhealthy
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Ingress object summary for ${NAMESPACE}:\n\n${ingress_object_summary.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Check for Ingress and Service Conflicts
    [Documentation]    Look for conflicting configuration between service and ingress objects.  
    [Tags]    service    ingress    health    conflict
    ${ingress_object_conflict}=    RW.CLI.Run Cli
    ...    cmd=CONTEXT="${CONTEXT}"; NAMESPACE="${NAMESPACE}"; ${KUBERNETES_DISTRIBUTION_BINARY} --context "${CONTEXT}" --namespace "${NAMESPACE}" get ingress -o json | jq -r '.items[] | select(.status.loadBalancer.ingress) | .metadata.name as \$name | .status.loadBalancer.ingress[0].ip as \$ingress_ip | .spec.rules[]?.http.paths[]? | "\\($name) \\($ingress_ip) \\(.backend.service.name) \\(.backend.service.port.number)"' | while read -r ingress_name ingress_ip service_name service_port; do ${KUBERNETES_DISTRIBUTION_BINARY} --context "${CONTEXT}" --namespace "${NAMESPACE}" get svc "$service_name" -o json | jq --arg ingress_name "$ingress_name" --arg ingress_ip "$ingress_ip" --arg service_name "$service_name" --arg service_port "$service_port" -r 'if .spec.type == "LoadBalancer" then .status.loadBalancer.ingress[0].ip as $service_ip | if $ingress_ip and $service_ip and $service_ip != $ingress_ip then "WARNING: Ingress \\($ingress_name) IP (\\($ingress_ip)) differs from Service \\($service_name) IP (\\($service_ip))" else "OK: Ingress \\($ingress_name) - Service \\($service_name) is of type LoadBalancer with IP (\\($service_ip))" end else "OK: Ingress \\($ingress_name) - Service \\($service_name) is of type \\(.spec.type) on port \\($service_port)" end'; done
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${matches}=    Get Lines Matching Regexp    ${ingress_object_conflict.stdout}    ^WARNING: Ingress [\\w-]+.*
    @{lines}=    Create List    ${matches}
    FOR    ${line}    IN    @{lines}
        ${ingress_name}=    RW.CLI.Run Cli
        ...    cmd=echo "${line}" | awk '/^WARNING: Ingress /{print $3}' | tr -d '\n'
        ...    env=${env}
        ${service_name}=    RW.CLI.Run Cli
        ...    cmd=echo "${line}" | awk -F'Service | IP' '{print $3}' | tr -d '\n'
        ...    env=${env}  
        ${warning_details}=    RW.CLI.Run Cli
        ...    cmd=CONTEXT="${CONTEXT}"; NAMESPACE="${NAMESPACE}"; ${KUBERNETES_DISTRIBUTION_BINARY} get ingress ${ingress_name.stdout} -n $NAMESPACE --context $CONTEXT -o yaml && ${KUBERNETES_DISTRIBUTION_BINARY} get svc ${service_name.stdout} -n $NAMESPACE --context $CONTEXT -o yaml
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        ${next_steps}=     Catenate  SEPERATOR=\${\n}
        ...    Review the current configuration of the ingress `${ingress_name.stdout}` to identify any conflicts.
        ...    Check the service type for `${service_name.stdout}` and ensure it is set to ClusterIP or NodePort instead of LoadBalancer.
        ...    Adjust the `${service_name.stdout}` service definition if it is incorrectly set to use a LoadBalancer.
        ...    Validate that the ingress `${ingress_name.stdout}` and service `${service_name.stdout}` configurations are aligned with the intended access patterns and security policies.
        RW.Core.Add Issue
            ...    severity=2
            ...    expected=Ingress objects should point at service types of ClusterIP. 
            ...    actual=There is a configuraiton mismatch between the Ingress object and Service object. 
            ...    reproduce_hint=${warning_details.cmd}
            ...    title=Ingress `${ingress_name.stdout}` in namespace `${NAMESPACE}` has a likely configuration conflict with service `${service_name.stdout}`.
            ...    details=`${line}\n${warning_details.stdout}`
            ...    next_steps=The ingress `${ingress_name.stdout}` has a likely configuration conflict with service `${service_name.stdout}`. In most cases, ingress objects should point to a service of type ClusterIP or NodePort, not LoadBalancer.\n${next_steps}        
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Ingress and service conflict summary for `${NAMESPACE}`:\n\n`${ingress_object_conflict.stdout}`
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
    ...    description=The name of the Kubernetes namespace to scope actions and searching to.
    ...    pattern=\w*
    ...    example=my-namespace
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Kubernetes context to operate within.
    ...    pattern=\w*
    ...    example=my-main-cluster
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
