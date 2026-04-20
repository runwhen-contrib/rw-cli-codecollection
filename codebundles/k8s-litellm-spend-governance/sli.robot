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
    ...    description=Kubeconfig for workspace alignment and (optional) port-forward / Secret reads.
    ...    pattern=\w*
    ${litellm_master_key_provided}=    Set Variable    ${FALSE}
    TRY
        ${litellm_master_key}=    RW.Core.Import Secret    litellm_master_key
        ...    type=string
        ...    description=Optional bearer token for LiteLLM Admin and spend routes. When omitted the SLI will try to derive it from a Kubernetes Secret in NAMESPACE.
        ...    pattern=\w*
        Set Suite Variable    ${litellm_master_key}    ${litellm_master_key}
        ${litellm_master_key_provided}=    Set Variable    ${TRUE}
    EXCEPT
        Log    litellm_master_key secret not provided; will try to derive from a Kubernetes Secret in the namespace.    INFO
        Set Suite Variable    ${litellm_master_key}    ${EMPTY}
    END
    Set Suite Variable    ${litellm_master_key_provided}    ${litellm_master_key_provided}
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Kubernetes context used when auto port-forwarding or resolving the master key.
    ...    pattern=\w*
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=Namespace where the LiteLLM service runs.
    ...    pattern=\w*
    ${PROXY_BASE_URL}=    RW.Core.Import User Variable    PROXY_BASE_URL
    ...    type=string
    ...    description=Optional LiteLLM proxy base URL. Leave empty to auto port-forward to the Service via kubectl.
    ...    pattern=.*
    ...    default=
    ${LITELLM_SERVICE_NAME}=    RW.Core.Import User Variable    LITELLM_SERVICE_NAME
    ...    type=string
    ...    description=Service name for labels and (when port-forwarding) the target Service.
    ...    pattern=\w*
    ${LITELLM_HTTP_PORT}=    RW.Core.Import User Variable    LITELLM_HTTP_PORT
    ...    type=string
    ...    description=Service port number for the proxy HTTP listener (used when auto port-forwarding).
    ...    pattern=^\d+$
    ...    default=4000
    ${RW_LOOKBACK_WINDOW}=    RW.Core.Import Platform Variable    RW_LOOKBACK_WINDOW
    ...    type=string
    ...    description=Lookback window mapped to spend log date filters.
    ...    pattern=\w*
    ...    default=24h
    ${LITELLM_SPEND_THRESHOLD_USD}=    RW.Core.Import User Variable    LITELLM_SPEND_THRESHOLD_USD
    ...    type=string
    ...    description=USD threshold for global spend dimension (0 disables strict threshold scoring).
    ...    pattern=^[0-9.]+$
    ...    default=0
    ${LITELLM_EXCEPTION_RATE_PCT}=    RW.Core.Import User Variable    LITELLM_EXCEPTION_RATE_PCT
    ...    type=string
    ...    description=Percent of requests in the lookback window that may fail before the exceptions dimension scores 0. Default 1 = 1%.
    ...    pattern=^[0-9.]+$
    ...    default=1
    ${LITELLM_MASTER_KEY_SECRET_NAME}=    RW.Core.Import User Variable    LITELLM_MASTER_KEY_SECRET_NAME
    ...    type=string
    ...    description=Optional Kubernetes Secret name in NAMESPACE to read the master key from when the litellm_master_key secret is not provided.
    ...    pattern=.*
    ...    default=
    ${LITELLM_MASTER_KEY_SECRET_KEY}=    RW.Core.Import User Variable    LITELLM_MASTER_KEY_SECRET_KEY
    ...    type=string
    ...    description=Optional data key within LITELLM_MASTER_KEY_SECRET_NAME. Leave empty to try common keys (masterkey, master_key, MASTER_KEY, LITELLM_MASTER_KEY).
    ...    pattern=.*
    ...    default=
    ${LITELLM_MASTER_KEY_INFER_FROM_POD}=    RW.Core.Import User Variable    LITELLM_MASTER_KEY_INFER_FROM_POD
    ...    type=string
    ...    description=When true (default), inspect the LiteLLM Pod env vars and follow any secretKeyRef to derive the key.
    ...    pattern=\w*
    ...    default=true
    ${LITELLM_MASTER_KEY_EXEC_FALLBACK}=    RW.Core.Import User Variable    LITELLM_MASTER_KEY_EXEC_FALLBACK
    ...    type=string
    ...    description=When true (default), fall back to `kubectl exec <pod> -- printenv LITELLM_MASTER_KEY` if Pod spec inspection cannot resolve the secretKeyRef.
    ...    pattern=\w*
    ...    default=true
    ${LITELLM_MASTER_KEY_SECRET_PATTERN}=    RW.Core.Import User Variable    LITELLM_MASTER_KEY_SECRET_PATTERN
    ...    type=string
    ...    description=Regex used to auto-discover a master key Secret by name as a last-resort fallback.
    ...    pattern=.*
    ...    default=litellm
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
    Set Suite Variable    ${LITELLM_HTTP_PORT}    ${LITELLM_HTTP_PORT}
    Set Suite Variable    ${RW_LOOKBACK_WINDOW}    ${RW_LOOKBACK_WINDOW}
    Set Suite Variable    ${LITELLM_SPEND_THRESHOLD_USD}    ${LITELLM_SPEND_THRESHOLD_USD}
    Set Suite Variable    ${LITELLM_EXCEPTION_RATE_PCT}    ${LITELLM_EXCEPTION_RATE_PCT}
    Set Suite Variable    ${LITELLM_MASTER_KEY_SECRET_NAME}    ${LITELLM_MASTER_KEY_SECRET_NAME}
    Set Suite Variable    ${LITELLM_MASTER_KEY_SECRET_KEY}    ${LITELLM_MASTER_KEY_SECRET_KEY}
    Set Suite Variable    ${LITELLM_MASTER_KEY_INFER_FROM_POD}    ${LITELLM_MASTER_KEY_INFER_FROM_POD}
    Set Suite Variable    ${LITELLM_MASTER_KEY_EXEC_FALLBACK}    ${LITELLM_MASTER_KEY_EXEC_FALLBACK}
    Set Suite Variable    ${LITELLM_MASTER_KEY_SECRET_PATTERN}    ${LITELLM_MASTER_KEY_SECRET_PATTERN}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}

    ${env}=    Create Dictionary
    ...    CONTEXT=${CONTEXT}
    ...    NAMESPACE=${NAMESPACE}
    ...    PROXY_BASE_URL=${PROXY_BASE_URL}
    ...    LITELLM_SERVICE_NAME=${LITELLM_SERVICE_NAME}
    ...    LITELLM_HTTP_PORT=${LITELLM_HTTP_PORT}
    ...    RW_LOOKBACK_WINDOW=${RW_LOOKBACK_WINDOW}
    ...    LITELLM_SPEND_THRESHOLD_USD=${LITELLM_SPEND_THRESHOLD_USD}
    ...    LITELLM_EXCEPTION_RATE_PCT=${LITELLM_EXCEPTION_RATE_PCT}
    ...    LITELLM_MASTER_KEY_SECRET_NAME=${LITELLM_MASTER_KEY_SECRET_NAME}
    ...    LITELLM_MASTER_KEY_SECRET_KEY=${LITELLM_MASTER_KEY_SECRET_KEY}
    ...    LITELLM_MASTER_KEY_INFER_FROM_POD=${LITELLM_MASTER_KEY_INFER_FROM_POD}
    ...    LITELLM_MASTER_KEY_EXEC_FALLBACK=${LITELLM_MASTER_KEY_EXEC_FALLBACK}
    ...    LITELLM_MASTER_KEY_SECRET_PATTERN=${LITELLM_MASTER_KEY_SECRET_PATTERN}
    ...    KUBERNETES_DISTRIBUTION_BINARY=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    KUBECONFIG=./${kubeconfig.key}
    Set Suite Variable    ${env}    ${env}
    Resolve LiteLLM Master Key

Resolve LiteLLM Master Key
    [Documentation]    Runs the master-key discovery script once so every task can reuse the cached value. Safe to run with or without an operator-provided secret.
    IF    ${litellm_master_key_provided}
        ${resolve_result}=    RW.CLI.Run Bash File
        ...    bash_file=resolve-litellm-master-key.sh
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        ...    secret__litellm_master_key=${litellm_master_key}
        ...    timeout_seconds=120
        ...    include_in_history=false
        ...    show_in_rwl_cheatsheet=false
        ...    cmd_override=./resolve-litellm-master-key.sh
    ELSE
        ${resolve_result}=    RW.CLI.Run Bash File
        ...    bash_file=resolve-litellm-master-key.sh
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        ...    timeout_seconds=120
        ...    include_in_history=false
        ...    show_in_rwl_cheatsheet=false
        ...    cmd_override=./resolve-litellm-master-key.sh
    END
    Log    ${resolve_result.stdout}


*** Tasks ***
Score LiteLLM Proxy Reachability for `${LITELLM_SERVICE_NAME}`
    [Documentation]    Binary 1 if /health or / returns HTTP 2xx within timeout.
    [Tags]    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sli-litellm-dimension.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
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
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./sli-litellm-dimension.sh threshold
    ${s}=    Strip String    ${result.stdout}
    ${score_th}=    Convert To Number    ${s}
    Set Suite Variable    ${score_th}
    RW.Core.Push Metric    ${score_th}    sub_name=global_spend_threshold

Score Spend Logs Cleanliness for `${LITELLM_SERVICE_NAME}`
    [Documentation]    Binary 1 when the /spend/logs summary endpoint parses cleanly or is unavailable on OSS (neutral pass). Uses summarize=true so a >100 MB raw log response on a busy proxy cannot drop the request.
    [Tags]    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sli-litellm-dimension.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./sli-litellm-dimension.sh logs
    ${s}=    Strip String    ${result.stdout}
    ${score_logs}=    Convert To Number    ${s}
    Set Suite Variable    ${score_logs}
    RW.Core.Push Metric    ${score_logs}    sub_name=spend_logs_clean

Score Spend Tracking Readiness for `${LITELLM_SERVICE_NAME}`
    [Documentation]    Binary 1 when /health/readiness reports db=connected, so spend-governance tasks have a DB to query. This is the authoritative "is spend tracking configured" signal.
    [Tags]    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sli-litellm-dimension.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./sli-litellm-dimension.sh readiness
    ${s}=    Strip String    ${result.stdout}
    ${score_ready}=    Convert To Number    ${s}
    Set Suite Variable    ${score_ready}
    RW.Core.Push Metric    ${score_ready}    sub_name=spend_db_connected

Score Exception Rate for `${LITELLM_SERVICE_NAME}`
    [Documentation]    Binary 1 when exception_rate across top model deployments stays under LITELLM_EXCEPTION_RATE_PCT. Uses OSS /global/activity endpoints (compact payloads).
    [Tags]    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sli-litellm-dimension.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./sli-litellm-dimension.sh exceptions
    ${s}=    Strip String    ${result.stdout}
    ${score_ex}=    Convert To Number    ${s}
    Set Suite Variable    ${score_ex}
    RW.Core.Push Metric    ${score_ex}    sub_name=exception_rate_ok

Generate LiteLLM Governance Health Score for `${LITELLM_SERVICE_NAME}`
    [Documentation]    Averages sub-scores (api reachable, readiness, global spend threshold, spend logs clean, exception rate) into the final 0-1 metric for alerting.
    [Tags]    access:read-only    data:metrics
    ${health_score}=    Evaluate    (${score_api} + ${score_ready} + ${score_th} + ${score_logs} + ${score_ex}) / 5
    ${health_score}=    Convert to Number    ${health_score}    2
    RW.Core.Add to Report    LiteLLM governance health score: ${health_score}
    RW.Core.Push Metric    ${health_score}
