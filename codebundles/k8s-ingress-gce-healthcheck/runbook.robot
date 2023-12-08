*** Settings ***
Documentation       Troubleshoot GCE Ingress Resources related to GCP HTTP Load Balancer in GKE
Metadata            Author    stewartshea
Metadata            Display Name    Kubernetes Ingress GCE & GCP HTTP Load Balancer Healthcheck
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
    ...    cmd=INGRESS_NAME=${INGRESS}; NAMESPACE=${NAMESPACE}; CONTEXT=${CONTEXT}; ${KUBERNETES_DISTRIBUTION_BINARY} get events -n $NAMESPACE --context $CONTEXT --field-selector involvedObject.kind=Ingress,involvedObject.name=$INGRESS_NAME,type!=Normal; for SERVICE_NAME in $(${KUBERNETES_DISTRIBUTION_BINARY} get ingress $INGRESS_NAME -n $NAMESPACE --context $CONTEXT -o=jsonpath='{.spec.rules[*].http.paths[*].backend.service.name}'); do ${KUBERNETES_DISTRIBUTION_BINARY} get events -n $NAMESPACE --context $CONTEXT --field-selector involvedObject.kind=Service,involvedObject.name=$SERVICE_NAME,type!=Normal; done
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true

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
    ...    cmd=INGRESS_NAME=${INGRESS}; NAMESPACE=${NAMESPACE}; CONTEXT=${CONTEXT}; ${KUBERNETES_DISTRIBUTION_BINARY} get ingress $INGRESS_NAME -n $NAMESPACE --context $CONTEXT -o=json | jq -r '.metadata.annotations["ingress.kubernetes.io/backends"] | fromjson | to_entries[] | select(.value != "HEALTHY") | "Backend: " + .key + " Status: " + .value'
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    show_in_rwl_cheatsheet=true

    RW.CLI.Parse Cli Output By Line
    ...    rsp=${unhealthy_backends}
    ...    set_severity_level=2
    ...    set_issue_expected=GCE HTTP Load Balancer should have all backends in a HEALTHY state for ingress `${INGRESS}`
    ...    set_issue_actual=GCE HTTP Load Balancer has unhealthy backends for ingress `${INGRESS}`
    ...    set_issue_title=GCE HTTP Load Balancer has unhealthy backends for ingress `${INGRESS}`
    ...    set_issue_details=The following GCP HTTP Load Balancer backends are not healthy :\n\n${unhealthy_backends.stdout}\n\n
    ...    set_issue_next_steps=Fetch Network Error Logs from GCP Operations Manager for HTTP Load Balancer for backends:\n\n${unhealthy_backends.stdout}\n\n
    ...    _line__raise_issue_if_contains=Backend
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report
    ...    GCE unhealthy backends in `${NAMESPACE}` for ingress `${INGRESS}`:\n\n${unhealthy_backends.stdout}
    RW.Core.Add Pre To Report    Commands Used: ${history}

Validate GCP HTTP Load Balancer Configurations
    [Documentation]    Extract GCP HTTP Load Balancer components from ingress annotations and check health of each object
    [Tags]    service    ingress    endpoint    health    backends    urlmap     gce
    ${gce_config_objects}=    RW.CLI.Run Bash File
    ...    bash_file=check_gce_ingress_objects.sh
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    env=${env}
    ...    include_in_history=false
    ...    timeout_seconds=120

    ${recommendations}=    RW.CLI.Run Cli
    ...    cmd=echo '''${gce_config_objects.stdout}''' | awk "/Recommendations:/ {start=1; getline} start"
    ...    env=${env}
    ...    include_in_history=false

    RW.CLI.Parse Cli Output By Line
    ...    rsp=${recommendations}
    ...    set_severity_level=3
    ...    set_issue_expected=GCP HTTP Load Balancer objects should exist in a healthy state for ingress: `${INGRESS}`
    ...    set_issue_actual=GCP HTTP Load Balancer objects are unhealthy, unknown, or missing for ingress : `${INGRESS}`
    ...    set_issue_title=Unhealthy or missing GCP HTTP Load Balancer configurations found for ingress `${INGRESS}`
    ...    set_issue_details=The following report is related to all GCP HTTP Load Balancer objects:\n\n${gce_config_objects.stdout}\n\n
    ...    set_issue_next_steps=${recommendations.stdout}
    ...    _line__raise_issue_if_contains=-
    ${history}=    RW.CLI.Pop Shell History
    RW.Core.Add Pre To Report    Ingress object summary for ingress: `${INGRESS}` in namespace: `${NAMESPACE}`:\n\n${gce_config_objects.stdout}


Fetch Network Error Logs from GCP Operations Manager for Ingress Backends
   [Documentation]    Fetch logs from the last 1d that are specific to the HTTP Load Balancer within the last 60 minutes
   [Tags]    service    ingress    endpoint    health
   ${network_error_logs}=    RW.CLI.Run Cli
    ...    cmd=INGRESS_NAME=${INGRESS}; NAMESPACE=${NAMESPACE}; CONTEXT=${CONTEXT}; GCP_PROJECT_ID=${GCP_PROJECT_ID};for backend in $(${KUBERNETES_DISTRIBUTION_BINARY} get ingress $INGRESS_NAME -n $NAMESPACE --context $CONTEXT -o=json | jq -r '.metadata.annotations["ingress.kubernetes.io/backends"] | fromjson | to_entries[] | select(.value != "HEALTHY") | .key'); do echo "Backend: \${backend}" && gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS && gcloud logging read 'severity="ERROR" AND resource.type="gce_network" AND protoPayload.resourceName=~"'\${backend}'"' --freshness=1d --limit=50 --project "$GCP_PROJECT_ID" --format=json | jq 'if length > 0 then [ .[] | select(.protoPayload.response.error.message? or .protoPayload.status.message?) | { timestamp: .timestamp, ip: (if .protoPayload.request.networkEndpoints? then .protoPayload.request.networkEndpoints[].ipAddress else null end), message: (.protoPayload.response.error.message? // .protoPayload.status.message?) } ] | group_by(.message) | map(max_by(.timestamp)) | .[] | (.timestamp + " | IP: " + (.ip // "N/A") + " | Error: " + .message) else "No results found" end'; done
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    show_in_rwl_cheatsheet=true
   
   RW.CLI.Parse Cli Output By Line
   ...    rsp=${network_error_logs}
   ...    set_severity_level=2
   ...    set_issue_expected=No network error logs should be found related to Ingress `${INGRESS}`
   ...    set_issue_actual=Network error logs are found in GCP Operations Console related to Ingress `${INGRESS}`
   ...    set_issue_title=Network error logs are found for Ingress `${INGRESS}`
   ...    set_issue_details=Network error logs were found:\n\n${network_error_logs.stdout}\n\n
   ...    set_issue_next_steps=Review Logs and check GCP documentation to help verify configuration accuracy. 
   ...    set_issue_reproduce_hint=Check the ingress object for related annotations. Inspect those objects in the GCP Console. 
   ...    _line__raise_issue_if_contains=
   ${history}=    RW.CLI.Pop Shell History
   RW.Core.Add Pre To Report    Network error logs possibly related to Ingress ${INGRESS}:\n\n${network_error_logs.stdout}
   RW.Core.Add Pre To Report    Commands Used: ${history}

Review GCP Operations Logging Dashboard
   [Documentation]    Create urls that will help users obtain logs from the GCP Dashboard
   [Tags]    service    ingress    endpoint    health    logging    http    loadbalancer
   ${loadbalancer_log_url}=   RW.CLI.Run CLI
    ...    cmd=INGRESS=${INGRESS}; NAMESPACE=${NAMESPACE}; CONTEXT=${CONTEXT}; FORWARDING_RULE=$(${KUBERNETES_DISTRIBUTION_BINARY} get ingress $INGRESS -n $NAMESPACE --context $CONTEXT -o=jsonpath='{.metadata.annotations.ingress\\.kubernetes\\.io/forwarding-rule}') && URL_MAP=$(${KUBERNETES_DISTRIBUTION_BINARY} get ingress $INGRESS -n $NAMESPACE --context $CONTEXT -o=jsonpath='{.metadata.annotations.ingress\\.kubernetes\\.io/url-map}') && TARGET_PROXY=$(${KUBERNETES_DISTRIBUTION_BINARY} get ingress $INGRESS -n $NAMESPACE --context $CONTEXT -o=jsonpath='{.metadata.annotations.ingress\\.kubernetes\\.io/target-proxy}') && LOG_QUERY="resource.type=\\"http_load_balancer\\" AND resource.labels.forwarding_rule_name=\\"$FORWARDING_RULE\\" AND resource.labels.target_proxy_name=\\"$TARGET_PROXY\\" AND resource.labels.url_map_name=\\"$URL_MAP\\"" && ENCODED_LOG_QUERY=$(echo $LOG_QUERY | sed -e 's| |%20|g' -e 's|"|%22|g' -e 's|(|%28|g' -e 's|)|%29|g' -e 's|=|%3D|g' -e 's|/|%2F|g') && GCP_LOGS_URL="https://console.cloud.google.com/logs/query;query=$ENCODED_LOG_QUERY?project=$GCP_PROJECT_ID" && echo $GCP_LOGS_URL
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    secret_file__gcp_credentials_json=${gcp_credentials_json}
    ...    env=${env}
    ...    show_in_rwl_cheatsheet=true
   ${backend_log_url}=   RW.CLI.Run Cli
    ...    cmd=INGRESS=${INGRESS}; NAMESPACE=${NAMESPACE}; CONTEXT=${CONTEXT}; QUERY="resource.type=\\"gce_network\\"" && for backend in $(${KUBERNETES_DISTRIBUTION_BINARY} get ingress $INGRESS -n $NAMESPACE --context $CONTEXT -o=json | jq -r '.metadata.annotations["ingress.kubernetes.io/backends"] | fromjson | to_entries[] | select(.value != "HEALTHY") | .key'); do QUERY="$QUERY AND protoPayload.resourceName=~\\"$backend\\""; done && ENCODED_QUERY=$(echo $QUERY | jq -sRr @uri) && DASHBOARD_URL="https://console.cloud.google.com/logs/query;query=$ENCODED_QUERY?project=$GCP_PROJECT_ID" && echo $DASHBOARD_URL
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    env=${env}
    ...    show_in_rwl_cheatsheet=true
   ${history}=    RW.CLI.Pop Shell History
   RW.Core.Add Pre To Report    GCP Ops Logs for HTTP Load Balancer ${INGRESS}:\n\n${loadbalancer_log_url.stdout}
   RW.Core.Add Pre To Report    GCP Ops Logs for ${INGRESS} backends:\n\n${backend_log_url.stdout}
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
    ${INGRESS}=    RW.Core.Import User Variable    INGRESS
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
    ${OS_PATH}=    Get Environment Variable    PATH

    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${INGRESS}    ${INGRESS}
    Set Suite Variable    ${gcp_credentials_json}    ${gcp_credentials_json}
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable
    ...    ${env}
    ...    {"KUBECONFIG":"./${kubeconfig.key}", "GCP_PROJECT_ID":"${GCP_PROJECT_ID}","CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","GOOGLE_APPLICATION_CREDENTIALS":"./${gcp_credentials_json.key}", "KUBERNETES_DISTRIBUTION_BINARY":"${KUBERNETES_DISTRIBUTION_BINARY}", "CONTEXT":"${CONTEXT}","NAMESPACE":"${NAMESPACE}","INGRESS":"${INGRESS}", "PATH":"$PATH:${OS_PATH}"}
