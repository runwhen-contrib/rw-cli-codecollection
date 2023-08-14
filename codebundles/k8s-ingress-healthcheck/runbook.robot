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
    ...    cmd=namespace="${NAMESPACE}"; context="${CONTEXT}"; for ingress in $(kubectl get ingress -n "$namespace" --context "$context" -ojsonpath='{range .items[*]}{.metadata.name}{"\\n"}{end}'); do echo "Ingress: $ingress"; health_status="NA"; services=(); backend_services=$(kubectl get ingress "$ingress" -n "$namespace" --context "$context" -ojsonpath='{range .spec.rules[*].http.paths[*]}{.backend.service.name}{"|"}{.backend.service.port.number}{"\\n"}{end}'); while IFS='|' read -r service port; do if [ -n "$service" ] && [ -n "$port" ]; then echo "Backend Service: $service, Port: $port"; service_exists=$(kubectl get service "$service" -n "$namespace" --context "$context" -ojsonpath='{.metadata.name}'); if [ -z "$service_exists" ]; then health_status="Unhealthy"; echo "Validation: Service $service does not exist"; else endpoint_pods=$(kubectl get endpoints "$service" -n "$namespace" --context "$context" -ojsonpath='{range .subsets[*].addresses[*]}- Pod Name: {.targetRef.name}\\n Pod IP: {.ip}\\n{end}'); if [ -z "$endpoint_pods" ]; then health_status="Unhealthy"; echo "Validation: Endpoint for service $service does not have any pods"; else echo "Endpoint Pod:"; echo "$endpoint_pods"; health_status="Healthy"; fi; fi; services+=("$service"); fi; done <<< "$backend_services"; if [ "$health_status" = "Unhealthy" ]; then echo "Health Status: $health_status"; echo "------------"; elif [ "$health_status" = "Healthy" ]; then echo "Health Status: $health_status"; fi; echo "------------"; done
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${unhealthy_objects}=    RW.CLI.Run Cli
    ...    cmd=echo "${ingress_object_summary.stdout}" | awk '/^Ingress:/ {rec=$0; next} {rec=rec ORS $0} /^Health Status: Unhealthy$/ {print rec ORS "------------"}'
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
    ...    set_issue_next_steps=${NAMESPACE} Troubleshoot Namespace Services And Application Workloads
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
