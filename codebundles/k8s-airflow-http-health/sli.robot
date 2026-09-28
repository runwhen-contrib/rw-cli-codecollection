*** Settings ***
Documentation     Measures Airflow webserver availability using GET /health, a lightweight REST API probe, and Kubernetes Service presence. Produces a value between 0 (failing) and 1 (healthy).
Metadata          Author    rw-codebundle-agent
Metadata          Display Name    Kubernetes Airflow HTTP/API Health SLI
Metadata          Supports    Kubernetes    AKS    EKS    GKE    OpenShift    Airflow

Suite Setup       Suite Initialization
Library           BuiltIn
Library           RW.Core
Library           RW.CLI
Library           RW.platform
Library           Collections


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration.
    ...    pattern=\w*
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Kubernetes context for kubectl-backed checks in the SLI.
    ...    pattern=\w*
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=Namespace where Airflow runs.
    ...    pattern=\w*
    ${PROXY_BASE_URL}=    RW.Core.Import User Variable    PROXY_BASE_URL
    ...    type=string
    ...    description=Optional base URL for Airflow HTTP. Leave empty to port-forward to the webserver Service.
    ...    pattern=.*
    ...    default=
    ${AIRFLOW_WEBSERVER_SERVICE_NAME}=    RW.Core.Import User Variable    AIRFLOW_WEBSERVER_SERVICE_NAME
    ...    type=string
    ...    description=Kubernetes Service name for the Airflow webserver.
    ...    pattern=.*
    ${AIRFLOW_HTTP_PORT}=    RW.Core.Import User Variable    AIRFLOW_HTTP_PORT
    ...    type=string
    ...    description=Service port for the Airflow web UI/API.
    ...    pattern=^\d+$
    ...    default=8080
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    enum=[kubectl,oc]
    ...    default=kubectl
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${PROXY_BASE_URL}    ${PROXY_BASE_URL}
    Set Suite Variable    ${AIRFLOW_WEBSERVER_SERVICE_NAME}    ${AIRFLOW_WEBSERVER_SERVICE_NAME}
    Set Suite Variable    ${AIRFLOW_HTTP_PORT}    ${AIRFLOW_HTTP_PORT}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    ${env}=    Create Dictionary
    ...    CONTEXT=${CONTEXT}
    ...    NAMESPACE=${NAMESPACE}
    ...    PROXY_BASE_URL=${PROXY_BASE_URL}
    ...    AIRFLOW_WEBSERVER_SERVICE_NAME=${AIRFLOW_WEBSERVER_SERVICE_NAME}
    ...    AIRFLOW_HTTP_PORT=${AIRFLOW_HTTP_PORT}
    ...    KUBERNETES_DISTRIBUTION_BINARY=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    KUBECONFIG=./${kubeconfig.key}
    Set Suite Variable    ${env}    ${env}


*** Tasks ***
Collect Airflow HTTP Sub-Scores for Service `${AIRFLOW_WEBSERVER_SERVICE_NAME}`
    [Documentation]    Fetches webserver /health, API reachability, and Kubernetes Service scores as binary 0/1 values.
    [Tags]    access:read-only    data:metrics
    ${raw}=    RW.CLI.Run Bash File
    ...    bash_file=sli-airflow-http-score.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./sli-airflow-http-score.sh
    TRY
        ${scores}=    Evaluate
        ...    next((json.loads(l) for l in reversed((r'''${raw.stdout}''').splitlines()) if l.strip().startswith('{') and l.strip().endswith('}')))
        ...    json
    EXCEPT
        Log    SLI score JSON parse failed; scoring all dimensions as 0.    WARN
        Log    ${raw.stdout}    WARN
        ${scores}=    Create Dictionary    webserver_health=0    api_reachability=0    kubernetes_service=0
    END
    ${wv}=    Get From Dictionary    ${scores}    webserver_health
    ${av}=    Get From Dictionary    ${scores}    api_reachability
    ${kv}=    Get From Dictionary    ${scores}    kubernetes_service
    ${wv}=    Convert To Number    ${wv}
    ${av}=    Convert To Number    ${av}
    ${kv}=    Convert To Number    ${kv}
    Set Suite Variable    ${webserver_health_score}    ${wv}
    Set Suite Variable    ${api_score}    ${av}
    Set Suite Variable    ${kubernetes_service_score}    ${kv}
    RW.Core.Push Metric    ${wv}    sub_name=webserver_health
    RW.Core.Push Metric    ${av}    sub_name=api_reachability
    RW.Core.Push Metric    ${kv}    sub_name=kubernetes_service

Generate Aggregate Airflow HTTP Health Score for Service `${AIRFLOW_WEBSERVER_SERVICE_NAME}`
    [Documentation]    Averages sub-scores into the final 0-1 health metric used for alerting.
    [Tags]    access:read-only    data:metrics
    ${health_score}=    Evaluate    (${webserver_health_score} + ${api_score} + ${kubernetes_service_score}) / 3
    ${health_score}=    Convert To Number    ${health_score}    2
    ${report_msg}=    Set Variable    Airflow HTTP health score: ${health_score} (webserver_health=${webserver_health_score}, api_reachability=${api_score}, kubernetes_service=${kubernetes_service_score})
    RW.Core.Add To Report    ${report_msg}
    RW.Core.Push Metric    ${health_score}
