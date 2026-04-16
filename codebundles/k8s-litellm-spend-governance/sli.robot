*** Settings ***
Metadata          Author    rw-codebundle-agent
Documentation     Measures LiteLLM proxy governance health from Admin API reachability, global spend versus threshold, and spend-log failure heuristics. Produces a value between 0 (failing) and 1 (healthy).
Metadata          Display Name    Kubernetes LiteLLM Spend and Governance
Metadata          Supports    Kubernetes    LiteLLM    spend    governance
Suite Setup       Suite Initialization
Library           BuiltIn
Library           String
Library           RW.Core
Library           RW.CLI
Library           RW.platform


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret    kubeconfig
    ...    type=string
    ...    description=Kubeconfig for workspace alignment (not used by SLI curl checks).
    ...    pattern=\w*
    ${litellm_master_key}=    RW.Core.Import Secret    litellm_master_key
    ...    type=string
    ...    description=Bearer token for LiteLLM Admin and spend routes.
    ...    pattern=\w*
    ${PROXY_BASE_URL}=    RW.Core.Import User Variable    PROXY_BASE_URL
    ...    type=string
    ...    description=LiteLLM proxy base URL.
    ...    pattern=.*
    ${LITELLM_SERVICE_NAME}=    RW.Core.Import User Variable    LITELLM_SERVICE_NAME
    ...    type=string
    ...    description=Service name for labels.
    ...    pattern=\w*
    ${RW_LOOKBACK_WINDOW}=    RW.Core.Import User Variable    RW_LOOKBACK_WINDOW
    ...    type=string
    ...    description=Lookback window mapped to spend log date filters.
    ...    pattern=\w*
    ...    default=24h
    ${LITELLM_SPEND_THRESHOLD_USD}=    RW.Core.Import User Variable    LITELLM_SPEND_THRESHOLD_USD
    ...    type=string
    ...    description=USD threshold for global spend dimension (0 disables strict threshold scoring).
    ...    pattern=^[0-9.]+$
    ...    default=0
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${litellm_master_key}    ${litellm_master_key}
    Set Suite Variable    ${PROXY_BASE_URL}    ${PROXY_BASE_URL}
    Set Suite Variable    ${LITELLM_SERVICE_NAME}    ${LITELLM_SERVICE_NAME}
    Set Suite Variable    ${RW_LOOKBACK_WINDOW}    ${RW_LOOKBACK_WINDOW}
    Set Suite Variable    ${LITELLM_SPEND_THRESHOLD_USD}    ${LITELLM_SPEND_THRESHOLD_USD}
    ${env}=    Create Dictionary
    ...    PROXY_BASE_URL=${PROXY_BASE_URL}
    ...    LITELLM_SERVICE_NAME=${LITELLM_SERVICE_NAME}
    ...    RW_LOOKBACK_WINDOW=${RW_LOOKBACK_WINDOW}
    ...    LITELLM_SPEND_THRESHOLD_USD=${LITELLM_SPEND_THRESHOLD_USD}
    Set Suite Variable    ${env}    ${env}


*** Tasks ***
Score LiteLLM Proxy Reachability for `${LITELLM_SERVICE_NAME}`
    [Documentation]    Binary 1 if /health or / returns HTTP 2xx within timeout.
    [Tags]    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sli-litellm-dimension.sh
    ...    env=${env}
    ...    secret__litellm_master_key=${litellm_master_key}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./sli-litellm-dimension.sh api
    ${s}=    Strip String    ${result.stdout}
    ${score_api}=    Convert To Number    ${s}
    Set Suite Variable    ${score_api}
    RW.Core.Push Metric    ${score_api}    sub_name=api_reachable

Score Global Spend Threshold for `${LITELLM_SERVICE_NAME}`
    [Documentation]    Binary 1 if threshold is disabled, spend is under threshold, or the report cannot be fetched.
    [Tags]    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sli-litellm-dimension.sh
    ...    env=${env}
    ...    secret__litellm_master_key=${litellm_master_key}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./sli-litellm-dimension.sh threshold
    ${s}=    Strip String    ${result.stdout}
    ${score_th}=    Convert To Number    ${s}
    Set Suite Variable    ${score_th}
    RW.Core.Push Metric    ${score_th}    sub_name=global_spend_threshold

Score Spend Logs Cleanliness for `${LITELLM_SERVICE_NAME}`
    [Documentation]    Binary 1 when spend logs show no failure heuristics, or the route is unavailable (neutral pass).
    [Tags]    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sli-litellm-dimension.sh
    ...    env=${env}
    ...    secret__litellm_master_key=${litellm_master_key}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./sli-litellm-dimension.sh logs
    ${s}=    Strip String    ${result.stdout}
    ${score_logs}=    Convert To Number    ${s}
    Set Suite Variable    ${score_logs}
    RW.Core.Push Metric    ${score_logs}    sub_name=spend_logs_clean

Generate LiteLLM Governance Health Score for `${LITELLM_SERVICE_NAME}`
    [Documentation]    Averages sub-scores into the final 0-1 metric for alerting.
    [Tags]    access:read-only    data:metrics
    ${health_score}=    Evaluate    (${score_api} + ${score_th} + ${score_logs}) / 3
    ${health_score}=    Convert to Number    ${health_score}    2
    RW.Core.Add to Report    LiteLLM governance health score: ${health_score}
    RW.Core.Push Metric    ${health_score}
