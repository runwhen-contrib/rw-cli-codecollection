*** Settings ***
Documentation       Surfaces LiteLLM spend, budget, and failure signals from proxy Admin APIs for operational and cost governance.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Kubernetes LiteLLM Spend and Governance
Metadata            Supports    Kubernetes    LiteLLM    spend    governance    metrics

Force Tags          Kubernetes    LiteLLM    spend    governance    service

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             RW.K8sHelper

Suite Setup         Suite Initialization


*** Tasks ***
Check Spend Tracking Configuration for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`
    [Documentation]    Hits /health/readiness and /key/list to report whether a spend-tracking DB is wired up (so later tasks can distinguish "no DB" from "transient failure") and whether admin auth is working.
    [Tags]    Kubernetes    LiteLLM    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-litellm-spend-config.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-litellm-spend-config.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat spend_config_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for spend config task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=LiteLLM should expose /health/readiness with db=connected and admin API reachable for spend governance
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Spend tracking configuration:\n${result.stdout}

Review Recent Spend Logs for Failures for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`
    [Documentation]    Queries /spend/logs for the lookback window and flags rows matching budget, rate-limit, or provider failure heuristics.
    [Tags]    Kubernetes    LiteLLM    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=review-litellm-spend-logs.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./review-litellm-spend-logs.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat spend_logs_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for spend logs task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Spend logs should not show repeated budget blocks, rate limits, or provider hard failures
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Spend logs analysis:\n${result.stdout}

Check Global Spend Report Against Threshold for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`
    [Documentation]    Calls /global/spend/report for the computed date window and compares estimated spend to LITELLM_SPEND_THRESHOLD_USD when non-zero.
    [Tags]    Kubernetes    LiteLLM    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-litellm-global-spend.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-litellm-global-spend.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat global_spend_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for global spend task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Global spend should remain within configured governance thresholds
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Global spend check:\n${result.stdout}

Inspect Virtual Key Spend and Remaining Budget for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`
    [Documentation]    Uses /key/list when available to highlight keys near max_budget or with expired credentials.
    [Tags]    Kubernetes    LiteLLM    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=inspect-litellm-key-budgets.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./inspect-litellm-key-budgets.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat key_budget_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for key budget task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=API keys should stay under max_budget and remain valid before expiry
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Key budget inspection:\n${result.stdout}

Review User Budget and Rate Limit Status for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`
    [Documentation]    Calls /user/info for configured user_ids to surface soft_budget_cooldown and spend versus limits.
    [Tags]    Kubernetes    LiteLLM    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=review-litellm-user-budgets.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./review-litellm-user-budgets.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat user_budget_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for user budget task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Users should not be in soft budget cooldown during normal operations
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    User budget review:\n${result.stdout}

Summarize Team Budgets and Limits for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`
    [Documentation]    Queries /team/info for configured team identifiers to detect teams near max_budget or blocked traffic risk.
    [Tags]    Kubernetes    LiteLLM    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=summarize-litellm-team-budgets.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./summarize-litellm-team-budgets.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat team_budget_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for team budget task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Team spend should remain below max_budget under steady load
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Team budget summary:\n${result.stdout}

Summarize Spend by Model and User for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`
    [Documentation]    Aggregates per-model and per-user spend from /spend/logs?summarize=true (OSS-compatible, compact payload) and flags groups that exceed configured LITELLM_MODEL_SPEND_THRESHOLD_USD or LITELLM_USER_SPEND_THRESHOLD_USD.
    [Tags]    Kubernetes    LiteLLM    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=summarize-litellm-model-spend.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./summarize-litellm-model-spend.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat model_spend_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for model spend task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=No single model or user should exceed configured per-model / per-user spend thresholds
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Spend by model and user:\n${result.stdout}

Aggregate Error and Blocked Request Signals for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`
    [Documentation]    Derives triage counts for budget_exceeded, rate limits, HTTP 429, and 5xx signals from spend logs in one summary.
    [Tags]    Kubernetes    LiteLLM    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=aggregate-litellm-failure-signals.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./aggregate-litellm-failure-signals.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat aggregate_failure_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for aggregate failure task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Failure and blocked-request rates should stay low in the lookback window
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Aggregate failure signals:\n${result.stdout}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret    kubeconfig
    ...    type=string
    ...    description=Kubeconfig for kubectl connectivity checks.
    ...    pattern=\w*
    ${litellm_master_key_provided}=    Set Variable    ${FALSE}
    TRY
        ${litellm_master_key}=    RW.Core.Import Secret    litellm_master_key
        ...    type=string
        ...    description=Optional LiteLLM master or admin API key for spend/governance routes. When omitted the codebundle will try to derive it from a Kubernetes Secret in NAMESPACE.
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
    ...    description=Kubernetes context name.
    ...    pattern=\w*
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=Namespace where the LiteLLM service runs.
    ...    pattern=\w*
    ${PROXY_BASE_URL}=    RW.Core.Import User Variable    PROXY_BASE_URL
    ...    type=string
    ...    description=Optional LiteLLM proxy base URL (for example http://my-litellm.my-ns.svc.cluster.local:4000). Leave empty to auto port-forward to the Service via kubectl.
    ...    pattern=.*
    ...    default=
    ${LITELLM_SERVICE_NAME}=    RW.Core.Import User Variable    LITELLM_SERVICE_NAME
    ...    type=string
    ...    description=Kubernetes Service name for labeling and reports.
    ...    pattern=\w*
    ${LITELLM_HTTP_PORT}=    RW.Core.Import User Variable    LITELLM_HTTP_PORT
    ...    type=string
    ...    description=Service port number for the proxy HTTP listener (used when auto port-forwarding).
    ...    pattern=^\d+$
    ...    default=4000
    ${RW_LOOKBACK_WINDOW}=    RW.Core.Import Platform Variable    RW_LOOKBACK_WINDOW
    ...    type=string
    ...    description=Lookback window for spend logs and reports (e.g. 24h, 7d).
    ...    pattern=\w*
    ...    default=24h
    ${LITELLM_SPEND_THRESHOLD_USD}=    RW.Core.Import User Variable    LITELLM_SPEND_THRESHOLD_USD
    ...    type=string
    ...    description=Alert when global estimated spend exceeds this USD amount (0 disables).
    ...    pattern=^[0-9.]+$
    ...    default=0
    ${LITELLM_MODEL_SPEND_THRESHOLD_USD}=    RW.Core.Import User Variable    LITELLM_MODEL_SPEND_THRESHOLD_USD
    ...    type=string
    ...    description=Per-model spend threshold used by the Summarize Spend by Model task. 0 disables the issue but the report still lists top models by spend.
    ...    pattern=^[0-9.]+$
    ...    default=0
    ${LITELLM_USER_SPEND_THRESHOLD_USD}=    RW.Core.Import User Variable    LITELLM_USER_SPEND_THRESHOLD_USD
    ...    type=string
    ...    description=Per-user spend threshold used by the Summarize Spend by Model task. 0 disables the issue but the report still lists top users by spend.
    ...    pattern=^[0-9.]+$
    ...    default=0
    ${LITELLM_EXCEPTION_RATE_PCT}=    RW.Core.Import User Variable    LITELLM_EXCEPTION_RATE_PCT
    ...    type=string
    ...    description=Percent of requests in the lookback window that may fail before the aggregate failure task raises an issue. Default 1 = 1%.
    ...    pattern=^[0-9.]+$
    ...    default=1
    ${LITELLM_ENABLE_RAW_LOG_SCAN}=    RW.Core.Import User Variable    LITELLM_ENABLE_RAW_LOG_SCAN
    ...    type=string
    ...    description=Opt-in flag to additionally scan the raw /spend/logs response for failure keyword heuristics. Disabled by default because the response can exceed 100 MB on busy proxies and drop through a kubectl port-forward tunnel. Set to true only when querying a proxy with modest traffic or from inside the cluster.
    ...    enum=[true,false]
    ...    default=false
    ${LITELLM_USER_IDS}=    RW.Core.Import User Variable    LITELLM_USER_IDS
    ...    type=string
    ...    description=Comma-separated internal user_ids for /user/info (empty skips).
    ...    pattern=.*
    ...    default=${EMPTY}
    ${LITELLM_TEAM_IDS}=    RW.Core.Import User Variable    LITELLM_TEAM_IDS
    ...    type=string
    ...    description=Comma-separated team ids for /team/info (empty skips).
    ...    pattern=.*
    ...    default=${EMPTY}
    ${LITELLM_MASTER_KEY_SECRET_NAME}=    RW.Core.Import User Variable    LITELLM_MASTER_KEY_SECRET_NAME
    ...    type=string
    ...    description=Optional Kubernetes Secret name in NAMESPACE to read the master key from when the litellm_master_key secret is not provided. Leave empty to infer from the Pod env or auto-discover.
    ...    pattern=.*
    ...    default=
    ${LITELLM_MASTER_KEY_SECRET_KEY}=    RW.Core.Import User Variable    LITELLM_MASTER_KEY_SECRET_KEY
    ...    type=string
    ...    description=Optional data key within LITELLM_MASTER_KEY_SECRET_NAME. Leave empty to try common keys (masterkey, master_key, MASTER_KEY, LITELLM_MASTER_KEY).
    ...    pattern=.*
    ...    default=
    ${LITELLM_MASTER_KEY_INFER_FROM_POD}=    RW.Core.Import User Variable    LITELLM_MASTER_KEY_INFER_FROM_POD
    ...    type=string
    ...    description=When true (default), inspect the LiteLLM Pod env vars (e.g. LITELLM_MASTER_KEY) and follow any secretKeyRef to derive the key. Set to false to skip.
    ...    pattern=\w*
    ...    default=true
    ${LITELLM_MASTER_KEY_EXEC_FALLBACK}=    RW.Core.Import User Variable    LITELLM_MASTER_KEY_EXEC_FALLBACK
    ...    type=string
    ...    description=When true (default), fall back to `kubectl exec <pod> -- printenv LITELLM_MASTER_KEY` if Pod spec inspection cannot resolve the secretKeyRef. Set to false to forbid exec.
    ...    pattern=\w*
    ...    default=true
    ${LITELLM_MASTER_KEY_SECRET_PATTERN}=    RW.Core.Import User Variable    LITELLM_MASTER_KEY_SECRET_PATTERN
    ...    type=string
    ...    description=Regex used to auto-discover a master key Secret by name as a last-resort fallback when Pod env inference does not find anything.
    ...    pattern=.*
    ...    default=litellm
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Kubernetes CLI binary for connectivity verification.
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
    Set Suite Variable    ${LITELLM_MODEL_SPEND_THRESHOLD_USD}    ${LITELLM_MODEL_SPEND_THRESHOLD_USD}
    Set Suite Variable    ${LITELLM_USER_SPEND_THRESHOLD_USD}    ${LITELLM_USER_SPEND_THRESHOLD_USD}
    Set Suite Variable    ${LITELLM_EXCEPTION_RATE_PCT}    ${LITELLM_EXCEPTION_RATE_PCT}
    Set Suite Variable    ${LITELLM_ENABLE_RAW_LOG_SCAN}    ${LITELLM_ENABLE_RAW_LOG_SCAN}
    Set Suite Variable    ${LITELLM_USER_IDS}    ${LITELLM_USER_IDS}
    Set Suite Variable    ${LITELLM_TEAM_IDS}    ${LITELLM_TEAM_IDS}
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
    ...    LITELLM_MODEL_SPEND_THRESHOLD_USD=${LITELLM_MODEL_SPEND_THRESHOLD_USD}
    ...    LITELLM_USER_SPEND_THRESHOLD_USD=${LITELLM_USER_SPEND_THRESHOLD_USD}
    ...    LITELLM_EXCEPTION_RATE_PCT=${LITELLM_EXCEPTION_RATE_PCT}
    ...    LITELLM_ENABLE_RAW_LOG_SCAN=${LITELLM_ENABLE_RAW_LOG_SCAN}
    ...    LITELLM_USER_IDS=${LITELLM_USER_IDS}
    ...    LITELLM_TEAM_IDS=${LITELLM_TEAM_IDS}
    ...    LITELLM_MASTER_KEY_SECRET_NAME=${LITELLM_MASTER_KEY_SECRET_NAME}
    ...    LITELLM_MASTER_KEY_SECRET_KEY=${LITELLM_MASTER_KEY_SECRET_KEY}
    ...    LITELLM_MASTER_KEY_INFER_FROM_POD=${LITELLM_MASTER_KEY_INFER_FROM_POD}
    ...    LITELLM_MASTER_KEY_EXEC_FALLBACK=${LITELLM_MASTER_KEY_EXEC_FALLBACK}
    ...    LITELLM_MASTER_KEY_SECRET_PATTERN=${LITELLM_MASTER_KEY_SECRET_PATTERN}
    ...    KUBERNETES_DISTRIBUTION_BINARY=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    KUBECONFIG=./${kubeconfig.key}
    Set Suite Variable    ${env}    ${env}

    RW.K8sHelper.Verify Cluster Connectivity
    ...    binary=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    context=${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    Resolve LiteLLM Master Key

Resolve LiteLLM Master Key
    [Documentation]    Runs the master-key discovery script once so every task can reuse the cached value. Output is surfaced in the runbook report so operators can see where the key came from (or why it could not be derived).
    IF    ${litellm_master_key_provided}
        ${resolve_result}=    RW.CLI.Run Bash File
        ...    bash_file=resolve-litellm-master-key.sh
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        ...    secret__litellm_master_key=${litellm_master_key}
        ...    timeout_seconds=120
        ...    include_in_history=false
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=./resolve-litellm-master-key.sh
    ELSE
        ${resolve_result}=    RW.CLI.Run Bash File
        ...    bash_file=resolve-litellm-master-key.sh
        ...    env=${env}
        ...    secret_file__kubeconfig=${kubeconfig}
        ...    timeout_seconds=120
        ...    include_in_history=false
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=./resolve-litellm-master-key.sh
    END
    RW.Core.Add Pre To Report    Master key resolution:\n${resolve_result.stdout}
