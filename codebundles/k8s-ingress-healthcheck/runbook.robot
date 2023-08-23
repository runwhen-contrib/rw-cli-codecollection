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

Suite Setup         Suite Initialization


*** Tasks ***
Fetch Ingress Object Health in Namespace 
    [Documentation]    Fetches all ingress objects in the namespace and outputs the name, health status, services, and endpoints. 
    [Tags]    service    ingress    endpoint   health 
    ${ingress_object_summary}=    RW.CLI.Run Cli
    ...    cmd=NAMESPACE="${NAMESPACE}";CONTEXT="${CONTEXT}";ingresses=$(${KUBERNETES_DISTRIBUTION_BINARY} get ingress -n "$NAMESPACE" --context "$CONTEXT" -o jsonpath='{range .items[*]}{.metadata.name}{"\\n"}{end}');for ingress in $ingresses;do echo "Ingress: $ingress";health_status="NA";backend_services=$(${KUBERNETES_DISTRIBUTION_BINARY} get ingress "$ingress" -n "$NAMESPACE" --context "$CONTEXT" -o jsonpath='{range .spec.rules[*].http.paths[*]}{.backend.service.name}{"|"}{.backend.service.port.number}{"\\n"}{end}');while IFS='|' read -r service port;do echo "Backend Service: $service, Port: $port";target_ports=$(${KUBERNETES_DISTRIBUTION_BINARY} get service "$service" -n "$NAMESPACE" --context "$CONTEXT" -o jsonpath="{.spec.ports[?(@.port==$port)].targetPort}");service_exists=$(${KUBERNETES_DISTRIBUTION_BINARY} get service "$service" -n "$NAMESPACE" --context "$CONTEXT" -ojsonpath='{.metadata.name}');if [ -z "$service_exists" ];then health_status="Unhealthy";echo "Error: Service $service does not exist";echo "Next Step: Check namespace $NAMESPACE for service name $service.";continue;else selectors=$(${KUBERNETES_DISTRIBUTION_BINARY} get svc "$service" -n "$NAMESPACE" --context "$CONTEXT" -o jsonpath='{.spec.selector}');label_selector="";for key in $(echo $selectors | jq -r 'keys[]');do value=$(echo $selectors | jq -r --arg key "$key" '.[$key]');label_selector="\${label_selector}\${key}=\${value},";done;label_selector=\${label_selector::-1};found_owner=0;for kind in deployment statefulset daemonset;do matching_owners=$(${KUBERNETES_DISTRIBUTION_BINARY} get $kind -n "$NAMESPACE" --context "$CONTEXT" -l "$label_selector" -o jsonpath='{.items[*].metadata.name}');if [ -n "$matching_owners" ];then for owner in $matching_owners;do echo "Owner Kind: $kind";echo "Owner Name: $owner";found_owner=1;done;fi;done;if [ "$found_owner" == 0 ];then echo "Error: No matching deployment, statefulset, or daemonset found";echo "Next Step: Check namespace $NAMESPACE for deployment, statefulset, or daemonset with labels that match $label_selector";fi;port_found="No";associated_pods=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NAMESPACE" --context "$CONTEXT" -l "$label_selector" -o jsonpath='{.items[*].metadata.name}');for pod in $associated_pods;do container_ports=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod "$pod" -n "$NAMESPACE" --context "$CONTEXT" -o jsonpath='{.spec.containers[*].ports[*].containerPort}');for target_port in $target_ports;do if echo "$container_ports" | grep -wq "$target_port";then port_found="Yes";break;fi;done;done;if [ "$port_found" = "No" ];then health_status="Unhealthy";echo "Warning: targetPort $target_ports of service $service is not found as a containerPort in associated pods";else health_status="Healthy";fi;endpoint_pods=$(${KUBERNETES_DISTRIBUTION_BINARY} get endpoints "$service" -n "$NAMESPACE" --context "$CONTEXT" -ojsonpath='{range .subsets[*].addresses[*]}- Pod Name: {.targetRef.name}\\n Pod IP: {.ip}\\n{end}');if [ -z "$endpoint_pods" ];then health_status="Unhealthy";echo "Error: Endpoint for service $service does not have any pods"; echo "Next Step: Check namespace $NAMESPACE for failed pods";else echo "Endpoint Pod:";echo "$endpoint_pods";health_status="Healthy";fi;fi;done<<<"$backend_services";echo "Health Status: $health_status";echo "------------";done
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${unhealthy_objects}=    RW.CLI.Run Cli
    ...    cmd=echo "${ingress_object_summary.stdout}" | awk '/^Ingress:/ {rec=$0; next} {rec=rec ORS $0} /^Health Status: Unhealthy$/ {print rec ORS "------------"}'
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${unhealthy_objects_next_steps}=    RW.CLI.Run Cli
    ...    cmd=echo "${unhealthy_objects.stdout}" | grep '^Next Step:' | sed 's/Next Step: //'
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${unhealthy_objects}
    ...    set_severity_level=3
    ...    set_issue_expected=All ingress objects should have services and active endpoints in namespace: ${NAMESPACE}
    ...    set_issue_actual=Ingress objects missing services or endpoints found in namespace: ${NAMESPACE}
    ...    set_issue_title=Unhealthy ingress objects found in ${NAMESPACE}
    ...    set_issue_details=The following unhealthy objects were found:\n\n$${unhealthy_objects.stdout}\n\n
    ...    set_issue_next_steps=\n\n${unhealthy_objects_next_steps.stdout}
    ...    _line__raise_issue_if_contains=Unhealthy
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Ingress object summary for ${NAMESPACE}:\n\n${ingress_object_summary.stdout}
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
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
