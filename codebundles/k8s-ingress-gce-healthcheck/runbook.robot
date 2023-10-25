*** Settings ***
Documentation       Troubleshoot GCE Ingress Resources in GKE
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes Ingress GCE Healthcheck
Metadata            Supports    Kubernetes,GKE,GCE,GCP

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem

Suite Setup         Suite Initialization


*** Tasks ***
Search For GCE Ingress Warnings in GKE
    [Documentation]    Find warning events related to GCE Ingress and services objects
    [Tags]    service    ingress    endpoint    health    ingress-gce    gke
    ${event_warnings}=    RW.CLI.Run Cli
    ...    cmd=INGRESS_NAME=my-ingress; NAMESPACE=argo; ${KUBERNETES_DISTRIBUTION_BINARY} get events -n $NAMESPACE --field-selector involvedObject.kind=Ingress,involvedObject.name=$INGRESS_NAME,type!=Normal; for SERVICE_NAME in $(${KUBERNETES_DISTRIBUTION_BINARY} get ingress $INGRESS_NAME -n $NAMESPACE -o=jsonpath='{.spec.rules[*].http.paths[*].backend.service.name}'); do ${KUBERNETES_DISTRIBUTION_BINARY} get events -n $NAMESPACE --field-selector involvedObject.kind=Service,involvedObject.name=$SERVICE_NAME,type!=Normal; done
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true

    RW.CLI.Parse Cli Output By Line
    ...    rsp=${event_warnings}
    ...    set_severity_level=3
    ...    set_issue_expected=GCE ingress and services should not have warnings in namespace `${NAMESPACE}` for ingress `${INGRESS}`
    ...    set_issue_actual=Ingress and service objects have warnings in namespace `${NAMESPACE}` for ingress `${INGRESS}`
    ...    set_issue_title=Unhealthy GCE ingress or service objects found in namespace `${NAMESPACE}` for ingress `${INGRESS}`
    ...    set_issue_details=The following warning events were found:\n\n${event_warnings.stdout}\n\n
    ...    set_issue_next_steps=Validate GCP HTTP Load Balancer Configurations for ${INGRESS}
    ...    _line__raise_issue_if_contains=Warning
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    GCE Ingress warnings for ${NAMESPACE}:\n\n${event_warnings.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Identify Unhealthy GCE HTTP Ingress Backends
    [Documentation]    Checks the backend annotations on the ingress object to determine if they are not regstered as healthy
    [Tags]    service    ingress    endpoint    health    ingress-gce    gke
    ${unhealthy_backends}=    RW.CLI.Run Cli
    ...    cmd=INGRESS_NAME=my-ingress; NAMESPACE=argo; ${KUBERNETES_DISTRIBUTION_BINARY} get ingress $INGRESS_NAME -n $NAMESPACE -o=json | jq -r '.metadata.annotations["ingress.kubernetes.io/backends"] | fromjson | to_entries[] | select(.value != "HEALTHY") | "Backend: " + .key + " Status: " + .value'
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true

    RW.CLI.Parse Cli Output By Line
    ...    rsp=${unhealthy_backends}
    ...    set_severity_level=2
    ...    set_issue_expected=GCE HTTP Load Balancer should have all backends in a HEALTHY state for ingress `${INGRESS}`
    ...    set_issue_actual=GCE HTTP Load Balancer has unhealthy backends for ingress `${INGRESS}`
    ...    set_issue_title=GCE HTTP Load Balancer has unhealthy backends for ingress `${INGRESS}`
    ...    set_issue_details=The following GCP HTTP Load Balancer backends are not healthy :\n\n${unhealthy_backends.stdout}\n\n
    ...    set_issue_next_steps=Fetch Logs from GCP Operations Manager for HTTP Load Balancer for backends:\n\n${unhealthy_backends.stdout}\n\n
    ...    _line__raise_issue_if_contains=Backend
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    GCE Ingress warnings for ${NAMESPACE}:\n\n${unhealthy_backends.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

# Validate GCP HTTP Load Balancer Configurations
#     [Documentation]    Search for warnings or configuration errors in GCP HTTP Load Balancer
#     [Tags]    service    ingress    endpoint    health
#     ${ingress_object_summary}=    RW.CLI.Run Cli
#     ...    cmd=
#     ...    target_service=${kubectl}
#     ...    env=${env}
#     ...    secret_file__kubeconfig=${kubeconfig}
#     ...    render_in_commandlist=true

#     RW.CLI.Parse Cli Output By Line
#     ...    rsp=${unhealthy_objects}
#     ...    set_severity_level=3
#     ...    set_issue_expected=All ingress objects should have services and active endpoints in namespace: ${NAMESPACE}
#     ...    set_issue_actual=Ingress objects missing services or endpoints found in namespace: ${NAMESPACE}
#     ...    set_issue_title=Unhealthy ingress objects found in ${NAMESPACE}
#     ...    set_issue_details=The following unhealthy objects were found:\n\n${unhealthy_objects.stdout}\n\n
#     ...    set_issue_next_steps=\n\n${unhealthy_objects_next_steps.stdout}
#     ...    _line__raise_issue_if_contains=Unhealthy
#     ${history}=    RW.CLI.Pop Shell History
#     RW.Core.Add Pre To Report    Ingress object summary for ${NAMESPACE}:\n\n${ingress_object_summary.stdout}
#     RW.Core.Add Pre To Report    Commands Used: ${history}

# Validate Endpoint IPs are Routable
#     [Documentation]    Check that endpoint IPs are routable in the VPC based on cluster network configuration
#     [Tags]    service    ingress    endpoint    health
#     ${ingress_object_summary}=    RW.CLI.Run Cli
#     ...    cmd=
#     ...    target_service=${kubectl}
#     ...    env=${env}
#     ...    secret_file__kubeconfig=${kubeconfig}
#     ...    render_in_commandlist=true

#     RW.CLI.Parse Cli Output By Line
#     ...    rsp=${unhealthy_objects}
#     ...    set_severity_level=3
#     ...    set_issue_expected=All ingress objects should have services and active endpoints in namespace: ${NAMESPACE}
#     ...    set_issue_actual=Ingress objects missing services or endpoints found in namespace: ${NAMESPACE}
#     ...    set_issue_title=Unhealthy ingress objects found in ${NAMESPACE}
#     ...    set_issue_details=The following unhealthy objects were found:\n\n${unhealthy_objects.stdout}\n\n
#     ...    set_issue_next_steps=\n\n${unhealthy_objects_next_steps.stdout}
#     ...    _line__raise_issue_if_contains=Unhealthy
#     ${history}=    RW.CLI.Pop Shell History
#     RW.Core.Add Pre To Report    Ingress object summary for ${NAMESPACE}:\n\n${ingress_object_summary.stdout}
#     RW.Core.Add Pre To Report    Commands Used: ${history}

# Fetch Logs from GCP Operations Manager for HTTP Load Balancer
#     [Documentation]    Fetch logs that are specific to the HTTP Load Balancer within the last 60 minutes
#     [Tags]    service    ingress    endpoint    health
#     ${ingress_object_summary}=    RW.CLI.Run Cli
#     ...    cmd=
#     ...    target_service=${kubectl}
#     ...    env=${env}
#     ...    secret_file__kubeconfig=${kubeconfig}
#     ...    render_in_commandlist=true

#     RW.CLI.Parse Cli Output By Line
#     ...    rsp=${unhealthy_objects}
#     ...    set_severity_level=3
#     ...    set_issue_expected=All ingress objects should have services and active endpoints in namespace: ${NAMESPACE}
#     ...    set_issue_actual=Ingress objects missing services or endpoints found in namespace: ${NAMESPACE}
#     ...    set_issue_title=Unhealthy ingress objects found in ${NAMESPACE}
#     ...    set_issue_details=The following unhealthy objects were found:\n\n${unhealthy_objects.stdout}\n\n
#     ...    set_issue_next_steps=\n\n${unhealthy_objects_next_steps.stdout}
#     ...    _line__raise_issue_if_contains=Unhealthy
#     ${history}=    RW.CLI.Pop Shell History
#     RW.Core.Add Pre To Report    Ingress object summary for ${NAMESPACE}:\n\n${ingress_object_summary.stdout}
#     RW.Core.Add Pre To Report    Commands Used: ${history}

# Generate URL for GCP Operations Logging Dashboard
#     [Documentation]    Create a url that will help users obtain logs from the GCP Dashboard 
#     [Tags]    service    ingress    endpoint    health
#     ${ingress_object_summary}=    RW.CLI.Run Cli
#     ...    cmd=
#     ...    target_service=${kubectl}
#     ...    env=${env}
#     ...    secret_file__kubeconfig=${kubeconfig}
#     ...    render_in_commandlist=true

#     RW.CLI.Parse Cli Output By Line
#     ...    rsp=${unhealthy_objects}
#     ...    set_severity_level=3
#     ...    set_issue_expected=All ingress objects should have services and active endpoints in namespace: ${NAMESPACE}
#     ...    set_issue_actual=Ingress objects missing services or endpoints found in namespace: ${NAMESPACE}
#     ...    set_issue_title=Unhealthy ingress objects found in ${NAMESPACE}
#     ...    set_issue_details=The following unhealthy objects were found:\n\n${unhealthy_objects.stdout}\n\n
#     ...    set_issue_next_steps=\n\n${unhealthy_objects_next_steps.stdout}
#     ...    _line__raise_issue_if_contains=Unhealthy
#     ${history}=    RW.CLI.Pop Shell History
#     RW.Core.Add Pre To Report    Ingress object summary for ${NAMESPACE}:\n\n${ingress_object_summary.stdout}
#     RW.Core.Add Pre To Report    Commands Used: ${history}
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
    ${INGRESS}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Which Ingress object to troubleshoot.
    ...    pattern=\w*
    ...    example=my-ingress
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Which binary to use for Kubernetes CLI commands.
    ...    enum=[kubectl,oc]
    ...    example=kubectl
    ...    default=kubectl
    ${GCLOUD_SERVICE}=    RW.Core.Import Service    gcloud
    ...    type=string
    ...    description=The selected RunWhen Service to use for accessing services within a network.
    ...    pattern=\w*
    ...    example=gcloud-service.shared
    ...    default=gcloud-service.shared
    ${gcp_credentials_json}=    RW.Core.Import Secret    gcp_credentials_json
    ...    type=string
    ...    description=GCP service account json used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID to scope the API to.
    ...    pattern=\w*
    ...    example=myproject-ID
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${INGRESS}    ${INGRESS}
    Set Suite Variable    ${GCLOUD_SERVICE}    ${GCLOUD_SERVICE}
    Set Suite Variable    ${gcp_credentials_json}    ${gcp_credentials_json}
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${env}    {"KUBECONFIG":"./${kubeconfig.key}"}
