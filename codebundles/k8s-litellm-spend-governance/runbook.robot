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
Review Recent Spend Logs for Failures for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`
    [Documentation]    Queries /spend/logs for the lookback window and flags rows matching budget, rate-limit, or provider failure heuristics.
    [Tags]    Kubernetes    LiteLLM    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=review-litellm-spend-logs.sh
    ...    env=${env}
    ...    secret__litellm_master_key=${litellm_master_key}
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
    ...    secret__litellm_master_key=${litellm_master_key}
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
    ...    secret__litellm_master_key=${litellm_master_key}
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
    ...    secret__litellm_master_key=${litellm_master_key}
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
    ...    secret__litellm_master_key=${litellm_master_key}
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

Aggregate Error and Blocked Request Signals for LiteLLM `${LITELLM_SERVICE_NAME}` in `${NAMESPACE}`
    [Documentation]    Derives triage counts for budget_exceeded, rate limits, HTTP 429, and 5xx signals from spend logs in one summary.
    [Tags]    Kubernetes    LiteLLM    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=aggregate-litellm-failure-signals.sh
    ...    env=${env}
    ...    secret__litellm_master_key=${litellm_master_key}
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
    ${litellm_master_key}=    RW.Core.Import Secret    litellm_master_key
    ...    type=string
    ...    description=Bearer token with permissions for LiteLLM spend and admin routes.
    ...    pattern=\w*
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
    ...    description=LiteLLM proxy base URL reachable from the runner (cluster DNS or port-forward).
    ...    pattern=.*
    ${LITELLM_SERVICE_NAME}=    RW.Core.Import User Variable    LITELLM_SERVICE_NAME
    ...    type=string
    ...    description=Kubernetes Service name for labeling and reports.
    ...    pattern=\w*
    ${RW_LOOKBACK_WINDOW}=    RW.Core.Import User Variable    RW_LOOKBACK_WINDOW
    ...    type=string
    ...    description=Lookback window for spend logs and reports (e.g. 24h, 7d).
    ...    pattern=\w*
    ...    default=24h
    ${LITELLM_SPEND_THRESHOLD_USD}=    RW.Core.Import User Variable    LITELLM_SPEND_THRESHOLD_USD
    ...    type=string
    ...    description=Alert when global estimated spend exceeds this USD amount (0 disables).
    ...    pattern=^[0-9.]+$
    ...    default=0
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
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    description=Kubernetes CLI binary for connectivity verification.
    ...    enum=[kubectl,oc]
    ...    default=kubectl

    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${litellm_master_key}    ${litellm_master_key}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${PROXY_BASE_URL}    ${PROXY_BASE_URL}
    Set Suite Variable    ${LITELLM_SERVICE_NAME}    ${LITELLM_SERVICE_NAME}
    Set Suite Variable    ${RW_LOOKBACK_WINDOW}    ${RW_LOOKBACK_WINDOW}
    Set Suite Variable    ${LITELLM_SPEND_THRESHOLD_USD}    ${LITELLM_SPEND_THRESHOLD_USD}
    Set Suite Variable    ${LITELLM_USER_IDS}    ${LITELLM_USER_IDS}
    Set Suite Variable    ${LITELLM_TEAM_IDS}    ${LITELLM_TEAM_IDS}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}

    ${env}=    Create Dictionary
    ...    CONTEXT=${CONTEXT}
    ...    NAMESPACE=${NAMESPACE}
    ...    PROXY_BASE_URL=${PROXY_BASE_URL}
    ...    LITELLM_SERVICE_NAME=${LITELLM_SERVICE_NAME}
    ...    RW_LOOKBACK_WINDOW=${RW_LOOKBACK_WINDOW}
    ...    LITELLM_SPEND_THRESHOLD_USD=${LITELLM_SPEND_THRESHOLD_USD}
    ...    LITELLM_USER_IDS=${LITELLM_USER_IDS}
    ...    LITELLM_TEAM_IDS=${LITELLM_TEAM_IDS}
    ...    KUBECONFIG=./${kubeconfig.key}
    Set Suite Variable    ${env}    ${env}

    RW.K8sHelper.Verify Cluster Connectivity
    ...    binary=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    context=${CONTEXT}
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
