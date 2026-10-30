*** Settings ***
Documentation     Measures OpenObserve health using API reachability, workload replica readiness, and storage_metrics (S3 access failures). Produces a value between 0 (failing) and 1 (healthy).
Metadata          Author    rw-codebundle-agent
Metadata          Display Name    Kubernetes OpenObserve Health Check SLI
Metadata          Supports    Kubernetes    AKS    EKS    GKE    OpenShift    OpenObserve

Suite Setup       Suite Initialization
Library           BuiltIn
Library           RW.Core
Library           RW.CLI
Library           RW.platform
Library           Collections


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=Kubernetes kubeconfig for cluster access and the automatic port-forward.
    ...    pattern=\w*
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Kubernetes context for the target cluster.
    ...    pattern=\w*
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=Namespace where OpenObserve is deployed.
    ...    pattern=\w*
    ${OBJECT_NAME}=    RW.Core.Import User Variable    OBJECT_NAME
    ...    type=string
    ...    description=OpenObserve workload name (Deployment or StatefulSet) this SLX monitors.
    ...    pattern=\w*
    ${OPENOBSERVE_SERVICE_NAME}=    RW.Core.Import User Variable    OPENOBSERVE_SERVICE_NAME
    ...    type=string
    ...    description=Kubernetes Service name exposing the OpenObserve HTTP port. Auto-discovered from a Service whose name contains 'openobserve' when empty.
    ...    pattern=.*
    ...    default=
    ${OPENOBSERVE_HTTP_PORT}=    RW.Core.Import User Variable    OPENOBSERVE_HTTP_PORT
    ...    type=string
    ...    description=OpenObserve HTTP port on the Service.
    ...    pattern=^\d+$
    ...    default=5080
    ${OPENOBSERVE_LOCAL_PORT}=    RW.Core.Import User Variable    OPENOBSERVE_LOCAL_PORT
    ...    type=string
    ...    description=Local port used when auto port-forwarding.
    ...    pattern=^\d+$
    ...    default=5080
    ${OPENOBSERVE_ORGANIZATION}=    RW.Core.Import User Variable    OPENOBSERVE_ORGANIZATION
    ...    type=string
    ...    description=OpenObserve organization used in the API path (/api/{org}/...).
    ...    pattern=\w*
    ...    default=default
    ${OPENOBSERVE_BASE_URL}=    RW.Core.Import User Variable    OPENOBSERVE_BASE_URL
    ...    type=string
    ...    description=Optional direct Base URL. Leave empty to auto start kubectl port-forward to svc/${OPENOBSERVE_SERVICE_NAME}.
    ...    pattern=.*
    ...    default=
    ${OPENOBSERVE_API_TIMEOUT}=    RW.Core.Import User Variable    OPENOBSERVE_API_TIMEOUT
    ...    type=string
    ...    description=Timeout in seconds for API curl calls.
    ...    pattern=^\d+$
    ...    default=25
    ${STORAGE_S3_FAILURE_THRESHOLD}=    RW.Core.Import User Variable    STORAGE_S3_FAILURE_THRESHOLD
    ...    type=string
    ...    description=Max s3_access_failures per storage_metrics sample before the storage dimension fails.
    ...    pattern=^\d+$
    ...    default=10
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Kubernetes CLI binary to use.
    ...    enum=[kubectl,oc]
    ...    default=kubectl
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${OBJECT_NAME}    ${OBJECT_NAME}
    Set Suite Variable    ${OPENOBSERVE_SERVICE_NAME}    ${OPENOBSERVE_SERVICE_NAME}
    Set Suite Variable    ${OPENOBSERVE_HTTP_PORT}    ${OPENOBSERVE_HTTP_PORT}
    Set Suite Variable    ${OPENOBSERVE_LOCAL_PORT}    ${OPENOBSERVE_LOCAL_PORT}
    Set Suite Variable    ${OPENOBSERVE_ORGANIZATION}    ${OPENOBSERVE_ORGANIZATION}
    Set Suite Variable    ${OPENOBSERVE_BASE_URL}    ${OPENOBSERVE_BASE_URL}
    Set Suite Variable    ${OPENOBSERVE_API_TIMEOUT}    ${OPENOBSERVE_API_TIMEOUT}
    Set Suite Variable    ${STORAGE_S3_FAILURE_THRESHOLD}    ${STORAGE_S3_FAILURE_THRESHOLD}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    ${env}=    Create Dictionary
    ...    CONTEXT=${CONTEXT}
    ...    NAMESPACE=${NAMESPACE}
    ...    OBJECT_NAME=${OBJECT_NAME}
    ...    OPENOBSERVE_SERVICE_NAME=${OPENOBSERVE_SERVICE_NAME}
    ...    OPENOBSERVE_HTTP_PORT=${OPENOBSERVE_HTTP_PORT}
    ...    OPENOBSERVE_LOCAL_PORT=${OPENOBSERVE_LOCAL_PORT}
    ...    OPENOBSERVE_ORGANIZATION=${OPENOBSERVE_ORGANIZATION}
    ...    OPENOBSERVE_BASE_URL=${OPENOBSERVE_BASE_URL}
    ...    OPENOBSERVE_API_TIMEOUT=${OPENOBSERVE_API_TIMEOUT}
    ...    STORAGE_S3_FAILURE_THRESHOLD=${STORAGE_S3_FAILURE_THRESHOLD}
    ...    KUBERNETES_DISTRIBUTION_BINARY=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    KUBECONFIG=./${kubeconfig.key}
    Set Suite Variable    ${env}    ${env}


*** Tasks ***
Collect OpenObserve Health Sub-Scores for Workload `${OBJECT_NAME}`
    [Documentation]    Fetches API reachability, replica readiness, and storage health as binary 0/1 scores.
    [Tags]    access:read-only    data:metrics
    ${raw}=    RW.CLI.Run Bash File
    ...    bash_file=sli-openobserve-score.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./sli-openobserve-score.sh
    TRY
        ${scores}=    Evaluate
        ...    next((json.loads(l) for l in reversed((r'''${raw.stdout}''').splitlines()) if l.strip().startswith('{') and l.strip().endswith('}')))
        ...    json
    EXCEPT
        Log    SLI score JSON parse failed; scoring all dimensions as 0. Raw stdout follows.    WARN
        Log    ${raw.stdout}    WARN
        ${scores}=    Create Dictionary    api_health=0    replicas_ready=0    storage_healthy=0
    END
    ${ap}=    Get From Dictionary    ${scores}    api_health
    ${rp}=    Get From Dictionary    ${scores}    replicas_ready
    ${sp}=    Get From Dictionary    ${scores}    storage_healthy
    ${ap}=    Convert To Number    ${ap}
    ${rp}=    Convert To Number    ${rp}
    ${sp}=    Convert To Number    ${sp}
    Set Suite Variable    ${api_health_score}    ${ap}
    Set Suite Variable    ${replicas_ready_score}    ${rp}
    Set Suite Variable    ${storage_healthy_score}    ${sp}
    RW.Core.Push Metric    ${ap}    sub_name=api_health
    RW.Core.Push Metric    ${rp}    sub_name=replicas_ready
    RW.Core.Push Metric    ${sp}    sub_name=storage_healthy

Generate Aggregate OpenObserve Health Score for Workload `${OBJECT_NAME}`
    [Documentation]    Averages sub-scores into the final 0-1 health metric used for alerting.
    [Tags]    access:read-only    data:metrics
    ${health_score}=    Evaluate    (${api_health_score} + ${replicas_ready_score} + ${storage_healthy_score}) / 3
    ${health_score}=    Convert To Number    ${health_score}    2
    ${report_msg}=    Set Variable    OpenObserve health score: ${health_score} (api_health=${api_health_score}, replicas_ready=${replicas_ready_score}, storage_healthy=${storage_healthy_score})
    RW.Core.Add To Report    ${report_msg}
    RW.Core.Push Metric    ${health_score}