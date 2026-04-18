*** Settings ***
Documentation     Measures LiteLLM proxy availability using liveness and readiness HTTP endpoints and a lightweight Kubernetes Service existence check. Produces a value between 0 (failing) and 1 (healthy).
Metadata          Author    rw-codebundle-agent
Metadata          Display Name    Kubernetes LiteLLM Proxy API Health SLI
Metadata          Supports    Kubernetes    AKS    EKS    GKE    OpenShift    LiteLLM

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
    ...    description=Namespace where the LiteLLM proxy runs.
    ...    pattern=\w*
    ${PROXY_BASE_URL}=    RW.Core.Import User Variable    PROXY_BASE_URL
    ...    type=string
    ...    description=Optional base URL for the LiteLLM HTTP API. Leave empty to auto port-forward to the Service via kubectl.
    ...    pattern=.*
    ...    default=
    ${LITELLM_SERVICE_NAME}=    RW.Core.Import User Variable    LITELLM_SERVICE_NAME
    ...    type=string
    ...    description=Kubernetes Service name for the LiteLLM proxy.
    ...    pattern=\w*
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Kubernetes CLI binary to use.
    ...    enum=[kubectl,oc]
    ...    default=kubectl
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${PROXY_BASE_URL}    ${PROXY_BASE_URL}
    Set Suite Variable    ${LITELLM_SERVICE_NAME}    ${LITELLM_SERVICE_NAME}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    ${env}=    Create Dictionary
    ...    CONTEXT=${CONTEXT}
    ...    NAMESPACE=${NAMESPACE}
    ...    PROXY_BASE_URL=${PROXY_BASE_URL}
    ...    LITELLM_SERVICE_NAME=${LITELLM_SERVICE_NAME}
    ...    KUBERNETES_DISTRIBUTION_BINARY=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    KUBECONFIG=./${kubeconfig.key}
    Set Suite Variable    ${env}    ${env}


*** Tasks ***
Collect LiteLLM Proxy Sub-Scores for Service `${LITELLM_SERVICE_NAME}`
    [Documentation]    Fetches liveness, readiness, and Kubernetes Service scores as binary 0/1 values.
    [Tags]    access:read-only    data:metrics
    ${raw}=    RW.CLI.Run Bash File
    ...    bash_file=sli-litellm-proxy-score.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./sli-litellm-proxy-score.sh
    # The script may emit harmless chatter from helper scripts before the JSON
    # line, so extract the last line that parses as a JSON object. Fall back
    # to zero-scores if nothing parseable is found.
    TRY
        ${scores}=    Evaluate
        ...    next((json.loads(l) for l in reversed((r'''${raw.stdout}''').splitlines()) if l.strip().startswith('{') and l.strip().endswith('}')))
        ...    json
    EXCEPT
        Log    SLI score JSON parse failed; scoring all dimensions as 0. Raw stdout follows.    WARN
        Log    ${raw.stdout}    WARN
        ${scores}=    Create Dictionary    liveness=0    readiness=0    kubernetes_service=0
    END
    ${lv}=    Get From Dictionary    ${scores}    liveness
    ${rv}=    Get From Dictionary    ${scores}    readiness
    ${kv}=    Get From Dictionary    ${scores}    kubernetes_service
    ${lv}=    Convert To Number    ${lv}
    ${rv}=    Convert To Number    ${rv}
    ${kv}=    Convert To Number    ${kv}
    Set Suite Variable    ${liveness_score}    ${lv}
    Set Suite Variable    ${readiness_score}    ${rv}
    Set Suite Variable    ${kubernetes_service_score}    ${kv}
    RW.Core.Push Metric    ${lv}    sub_name=liveness
    RW.Core.Push Metric    ${rv}    sub_name=readiness
    RW.Core.Push Metric    ${kv}    sub_name=kubernetes_service

Generate Aggregate LiteLLM Proxy Health Score for Service `${LITELLM_SERVICE_NAME}`
    [Documentation]    Averages sub-scores into the final 0-1 health metric used for alerting.
    [Tags]    access:read-only    data:metrics
    ${health_score}=    Evaluate    (${liveness_score} + ${readiness_score} + ${kubernetes_service_score}) / 3
    ${health_score}=    Convert To Number    ${health_score}    2
    # Assign the message to a variable first; embedding `liveness=...` etc.
    # directly in the keyword call makes Robot's arg parser mistake the
    # tokens for named arguments of Add To Report.
    ${report_msg}=    Set Variable    LiteLLM proxy health score: ${health_score} (liveness=${liveness_score}, readiness=${readiness_score}, kubernetes_service=${kubernetes_service_score})
    RW.Core.Add To Report    ${report_msg}
    RW.Core.Push Metric    ${health_score}
