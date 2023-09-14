*** Settings ***
Documentation       Collects Nginx ingress host controller metrics from GMP on GCP and inspects the results for ingress with a HTTP error code rate greater than zero
...                 over a configurable duration and raises issues based on the number of ingress with error codes.
Metadata            Author    jon-funk
Metadata            Display Name    GKE Nginx Ingress Host Triage
Metadata            Supports    GCP,GMP,Ingress,Nginx,Metrics

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Fetch Nginx Ingress HTTP Errors From GMP And Perform Inspection On Results
    [Documentation]    Fetches metrics for the Nginx ingress host from GMP and performs an inspection on the results.
    ...    If there are currently any results with more than zero errors, their name will be surfaced for further troubleshooting.
    [Tags]    curl    http    ingress    latency    errors    metrics    controller    nginx    gmp    500s
    ${gmp_rsp}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && curl -d "query=rate(nginx_ingress_controller_requests{host='${INGRESS_HOST}', service='${INGRESS_SERVICE}', status=~'${ERROR_CODES}'}[${TIME_SLICE}]) > 0" -H "Authorization: Bearer $(gcloud auth print-access-token)" 'https://monitoring.googleapis.com/v1/projects/${GCP_PROJECT_ID}/location/global/prometheus/api/v1/query' | jq -r 'if .data.result[0] then "Host:" + .data.result[0].metric.host + " Ingress:" + .data.result[0].metric.ingress + " Namespace:" + .data.result[0].metric.exported_namespace + " Service:" + .data.result[0].metric.service else "" end'
    ...    render_in_commandlist=true
    ...    target_service=${GCLOUD_SERVICE}
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ${gmp_json}=    RW.CLI.Run Cli
    ...    cmd=gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && curl -d "query=rate(nginx_ingress_controller_requests{host='${INGRESS_HOST}', service='${INGRESS_SERVICE}', status=~'${ERROR_CODES}'}[${TIME_SLICE}]) > 0" -H "Authorization: Bearer $(gcloud auth print-access-token)" 'https://monitoring.googleapis.com/v1/projects/${GCP_PROJECT_ID}/location/global/prometheus/api/v1/query'
    ...    target_service=${GCLOUD_SERVICE}
    ...    env=${env}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ${k8s_ingress_details}=    RW.CLI.Run Cli
    ...    cmd=namespace="${NAMESPACE}"; context="${CONTEXT}"; ingress="${INGRESS_OBJECT_NAME}"; echo "Ingress: $ingress"; health_status="NA"; services=(); backend_services=$(${KUBERNETES_DISTRIBUTION_BINARY} get ingress "$ingress" -n "$namespace" --context "$context" -ojsonpath='{range .spec.rules[*].http.paths[*]}{.backend.service.name}{" "}{.backend.service.port.number}{"\\n"}{end}'); IFS=$'\\n'; for line in $backend_services; do service=$(echo "$line" | cut -d " " -f 1); port=$(echo "$line" | cut -d " " -f 2); if [ -n "$service" ] && [ -n "$port" ]; then echo "Backend Service: $service, Port: $port"; service_exists=$(${KUBERNETES_DISTRIBUTION_BINARY} get service "$service" -n "$namespace" --context "$context" -ojsonpath='{.metadata.name}'); if [ -z "$service_exists" ]; then health_status="Unhealthy"; echo "Validation: Service $service does not exist"; else endpoint_pods=$(${KUBERNETES_DISTRIBUTION_BINARY} get endpoints "$service" -n "$namespace" --context "$context" -ojsonpath='{range .subsets[*].addresses[*]}- Pod Name: {.targetRef.name}, Pod IP: {.ip}\\n{end}'); if [ -z "$endpoint_pods" ]; then health_status="Unhealthy"; echo "Validation: Endpoint for service $service does not have any pods"; else echo "Endpoint Pod:"; echo -e "$endpoint_pods"; for pod in $endpoint_pods; do if [[ $pod == *"- Pod Name: "* ]]; then pod_name="\${pod#*- Pod Name: }"; pod_name="\${pod_name%%,*}"; if [ -n "$pod_name" ]; then owner_kind=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod "$pod_name" -n "$namespace" --context "$context" -o=jsonpath='{.metadata.ownerReferences[0].kind}'); if [ -n "$owner_kind" ]; then if [ "$owner_kind" = "StatefulSet" ] || [ "$owner_kind" = "DaemonSet" ]; then owner_info="$(${KUBERNETES_DISTRIBUTION_BINARY} get pod "$pod_name" -n "$namespace" --context "$context" -o=jsonpath='{.metadata.ownerReferences[0].name}') $owner_kind"; else replicaset=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod "$pod_name" -n "$namespace" --context "$context" -o=jsonpath='{.metadata.ownerReferences[0].name}'); if [ -n "$replicaset" ]; then owner_kind=$(${KUBERNETES_DISTRIBUTION_BINARY} get replicaset "$replicaset" -n "$namespace" --context "$context" -o=jsonpath='{.metadata.ownerReferences[0].kind}'); owner_name=$(${KUBERNETES_DISTRIBUTION_BINARY} get replicaset "$replicaset" -n "$namespace" --context "$context" -o=jsonpath='{.metadata.ownerReferences[0].name}'); owner_info="$owner_kind:$owner_name"; fi; fi; fi; if [ -n "$owner_info" ]; then echo "Owner: $owner_info"; fi; fi; fi; done; health_status="Healthy"; fi; fi; services+=("$service"); fi; done; for service in "\${services[@]}"; do service_exists=$(${KUBERNETES_DISTRIBUTION_BINARY} get service "$service" -n "$namespace" --context "$context" -ojsonpath='{.metadata.name}'); if [ -z "$service_exists" ]; then health_status="Unhealthy"; echo "Validation: Service $service does not exist"; else endpoint_exists=$(${KUBERNETES_DISTRIBUTION_BINARY} get endpoints "$service" -n "$namespace" --context "$context" -ojsonpath='{.metadata.name}'); if [ -z "$endpoint_exists" ]; then health_status="Unhealthy"; echo "Validation: Endpoint for service $service does not exist"; fi; fi; done; if [ "$health_status" = "Unhealthy" ]; then echo "Health Status: $health_status"; echo "====================="; elif [ "$health_status" = "Healthy" ]; then echo "Health Status: $health_status"; fi; echo "------------"
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ${ingress_owner}=    RW.CLI.Run Cli
    ...    cmd=echo "${k8s_ingress_details.stdout}" | grep 'Owner:[^ ]*' | awk -F': ' '{print $2}'
    ...    target_service=${GCLOUD_SERVICE}
    RW.CLI.Parse Cli Output By Line
    ...    rsp=${gmp_rsp}
    ...    set_severity_level=2
    ...    set_issue_expected=The ingress in $_line should not have any HTTP responses with the following codes: ${ERROR_CODES}
    ...    set_issue_actual=We found the following HTTP error codes: ${ERROR_CODES} associated with the ingress in $_line
    ...    set_issue_title=Detected HTTP Error Codes Across Network
    ...    set_issue_details=HTTP error codes in ingress and service "$_line". Troubleshoot the application associated with: ${INGRESS_SERVICE}
    ...    set_issue_next_steps=Check Deployment Log For Issues\n\n${ingress_owner.stdout}
    ...    _line__raise_issue_if_contains=Host
    ${ingress_info}=    Set Variable    ${gmp_rsp.stdout}
    IF    """${ingress_info}""" == "" or """${ingress_info}""".isspace()
        ${ingress_info}=    Set Variable
        ...    No ingress with error codes: ${ERROR_CODES} within the timeframe ${TIME_SLICE}
        ...    Kubernetes Ingress Details include: \n${k8s_ingress_details.stdout}
    END
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
    RW.Core.Add Pre To Report    Ingress Info:\n${ingress_info} Ingress Owner:${ingress_owner.stdout}
    RW.Core.Add Pre To Report    GMP Json Data:\n${gmp_json.stdout}

Find Ingress Owner and Service Health
    [Documentation]    Checks the ingress object service and endpoints. Also returns the owner of the pods that support the Ingress.
    [Tags]    owner    ingress    service    endpoints
    ${k8s_ingress_details}=    RW.CLI.Run Cli
    ...    cmd=namespace="${NAMESPACE}"; context="${CONTEXT}"; ingress="${INGRESS_OBJECT_NAME}"; echo "Ingress: $ingress"; health_status="NA"; services=(); backend_services=$(${KUBERNETES_DISTRIBUTION_BINARY} get ingress "$ingress" -n "$namespace" --context "$context" -ojsonpath='{range .spec.rules[*].http.paths[*]}{.backend.service.name}{" "}{.backend.service.port.number}{"\\n"}{end}'); IFS=$'\\n'; for line in $backend_services; do service=$(echo "$line" | cut -d " " -f 1); port=$(echo "$line" | cut -d " " -f 2); if [ -n "$service" ] && [ -n "$port" ]; then echo "Backend Service: $service, Port: $port"; service_exists=$(${KUBERNETES_DISTRIBUTION_BINARY} get service "$service" -n "$namespace" --context "$context" -ojsonpath='{.metadata.name}'); if [ -z "$service_exists" ]; then health_status="Unhealthy"; echo "Validation: Service $service does not exist"; else endpoint_pods=$(${KUBERNETES_DISTRIBUTION_BINARY} get endpoints "$service" -n "$namespace" --context "$context" -ojsonpath='{range .subsets[*].addresses[*]}- Pod Name: {.targetRef.name}, Pod IP: {.ip}\\n{end}'); if [ -z "$endpoint_pods" ]; then health_status="Unhealthy"; echo "Validation: Endpoint for service $service does not have any pods"; else echo "Endpoint Pod:"; echo -e "$endpoint_pods"; for pod in $endpoint_pods; do if [[ $pod == *"- Pod Name: "* ]]; then pod_name="\${pod#*- Pod Name: }"; pod_name="\${pod_name%%,*}"; if [ -n "$pod_name" ]; then owner_kind=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod "$pod_name" -n "$namespace" --context "$context" -o=jsonpath='{.metadata.ownerReferences[0].kind}'); if [ -n "$owner_kind" ]; then if [ "$owner_kind" = "StatefulSet" ] || [ "$owner_kind" = "DaemonSet" ]; then owner_info="$(${KUBERNETES_DISTRIBUTION_BINARY} get pod "$pod_name" -n "$namespace" --context "$context" -o=jsonpath='{.metadata.ownerReferences[0].name}') $owner_kind"; else replicaset=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod "$pod_name" -n "$namespace" --context "$context" -o=jsonpath='{.metadata.ownerReferences[0].name}'); if [ -n "$replicaset" ]; then owner_kind=$(${KUBERNETES_DISTRIBUTION_BINARY} get replicaset "$replicaset" -n "$namespace" --context "$context" -o=jsonpath='{.metadata.ownerReferences[0].kind}'); owner_name=$(${KUBERNETES_DISTRIBUTION_BINARY} get replicaset "$replicaset" -n "$namespace" --context "$context" -o=jsonpath='{.metadata.ownerReferences[0].name}'); owner_info="$owner_name $owner_kind"; fi; fi; fi; if [ -n "$owner_info" ]; then echo "Owner: $owner_info"; fi; fi; fi; done; health_status="Healthy"; fi; fi; services+=("$service"); fi; done; for service in "\${services[@]}"; do service_exists=$(${KUBERNETES_DISTRIBUTION_BINARY} get service "$service" -n "$namespace" --context "$context" -ojsonpath='{.metadata.name}'); if [ -z "$service_exists" ]; then health_status="Unhealthy"; echo "Validation: Service $service does not exist"; else endpoint_exists=$(${KUBERNETES_DISTRIBUTION_BINARY} get endpoints "$service" -n "$namespace" --context "$context" -ojsonpath='{.metadata.name}'); if [ -z "$endpoint_exists" ]; then health_status="Unhealthy"; echo "Validation: Endpoint for service $service does not exist"; fi; fi; done; if [ "$health_status" = "Unhealthy" ]; then echo "Health Status: $health_status"; echo "====================="; elif [ "$health_status" = "Healthy" ]; then echo "Health Status: $health_status"; fi; echo "------------"
    ...    target_service=${kubectl}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    render_in_commandlist=true
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Commands Used: ${history}
    RW.Core.Add Pre To Report    Ingress Info:\n${k8s_ingress_details.stdout}


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
    ${INGRESS_HOST}=    RW.Core.Import User Variable
    ...    INGRESS_HOST
    ...    type=string
    ...    description=The hostname value of the ingress object.
    ...    pattern=\w*
    ...    example=online-boutique.sandbox.runwhen.com
    ${INGRESS_SERVICE}=    RW.Core.Import User Variable
    ...    INGRESS_SERVICE
    ...    type=string
    ...    description=The name of the service that is related to the ingress object.
    ...    pattern=\w*
    ...    example=frontend-external
    ${INGRESS_OBJECT_NAME}=    RW.Core.Import User Variable
    ...    INGRESS_OBJECT_NAME
    ...    type=string
    ...    description=The name of the ingress object in Kubernetes.
    ...    pattern=\w*
    ...    example=frontend-external
    ${TIME_SLICE}=    RW.Core.Import User Variable    TIME_SLICE
    ...    type=string
    ...    description=The amount of time to perform aggregations over.
    ...    pattern=\w*
    ...    example=60m
    ...    default=60m
    Set Suite Variable    ${TIME_SLICE}    ${TIME_SLICE}
    ${ERROR_CODES}=    RW.Core.Import User Variable    ERROR_CODES
    ...    type=string
    ...    description=Which http status codes to look for and classify as errors.
    ...    pattern=\w*
    ...    example=500
    ...    default=500|501|502
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${kubectl}    ${kubectl}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${ERROR_CODES}    ${ERROR_CODES}
    Set Suite Variable    ${GCLOUD_SERVICE}    ${GCLOUD_SERVICE}
    Set Suite Variable    ${gcp_credentials_json}    ${gcp_credentials_json}
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${INGRESS_HOST}    ${INGRESS_HOST}
    Set Suite Variable    ${INGRESS_SERVICE}    ${INGRESS_SERVICE}
    Set Suite Variable    ${INGRESS_OBJECT_NAME}    ${INGRESS_OBJECT_NAME}
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials_json.key}", "KUBECONFIG":"./${kubeconfig.key}"}
