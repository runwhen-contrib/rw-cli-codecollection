*** Settings ***
Documentation       Monitors OpenRouter API spending by checking account balance, aggregating spend from generation logs, breaking down costs by model, comparing against budget thresholds, forecasting future spend, and detecting anomalous spending patterns.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    OpenRouter Spend Health and Forecasting
Metadata            Supports    OpenRouter    spend    health    forecasting    budget

Force Tags          OpenRouter    spend    health    forecasting    budget

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check OpenRouter Account Balance for Account `${OPENROUTER_API_KEY_LABEL}`
    [Documentation]    Queries the OpenRouter /api/v1/auth/key endpoint for remaining credits. Raises an issue if balance is below the configured minimum threshold or if the API key is invalid or expired.
    [Tags]    OpenRouter    spend    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-openrouter-balance.sh
    ...    env=${env}
    ...    secret__OPENROUTER_API_KEY=${OPENROUTER_API_KEY}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-openrouter-balance.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat balance_issues.json
    ...    secret__OPENROUTER_API_KEY=${OPENROUTER_API_KEY}
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for balance check, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=OpenRouter account balance should be above the minimum threshold and the API key should be valid
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Balance check results:\n${result.stdout}

Review OpenRouter Spend History for Account `${OPENROUTER_API_KEY_LABEL}`
    [Documentation]    Fetches recent generation logs from /api/v1/logs, aggregates spend by day for the lookback window, and flags gaps in logging data.
    [Tags]    OpenRouter    spend    access:read-only    data:logs

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=review-openrouter-spend-history.sh
    ...    env=${env}
    ...    secret__openrouter_api_key=${OPENROUTER_API_KEY}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./review-openrouter-spend-history.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat spend_history_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for spend history, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Generation logs should be present for each day in the lookback window with no gaps
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Spend history review:\n${result.stdout}

Analyze OpenRouter Spend by Model for Account `${OPENROUTER_API_KEY_LABEL}`
    [Documentation]    Breaks down spend per model from the logs endpoint. Identifies the top-N most expensive models and flags any model whose share exceeds a configured concentration threshold.
    [Tags]    OpenRouter    spend    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze-openrouter-spend-by-model.sh
    ...    env=${env}
    ...    secret__openrouter_api_key=${OPENROUTER_API_KEY}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./analyze-openrouter-spend-by-model.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat model_spend_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for model spend, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=No single model should exceed the configured spend concentration threshold
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Model spend analysis:\n${result.stdout}

Check OpenRouter Budget Status for Account `${OPENROUTER_API_KEY_LABEL}`
    [Documentation]    Compares total cumulative spend against a configured budget threshold. Raises an issue if spend exceeds the budget or is projected to exceed it before the next reset period.
    [Tags]    OpenRouter    spend    access:read-only    data:config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-openrouter-budget.sh
    ...    env=${env}
    ...    secret__openrouter_api_key=${OPENROUTER_API_KEY}
    ...    timeout_seconds=60
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-openrouter-budget.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat budget_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for budget check, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Cumulative spend should remain within the configured budget threshold
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Budget status check:\n${result.stdout}

Forecast OpenRouter Spend Trend for Account `${OPENROUTER_API_KEY_LABEL}`
    [Documentation]    Computes average daily burn rate from the last N days of spend history, projects spend for the next period, and flags if projected spend would exceed the configured budget.
    [Tags]    OpenRouter    spend    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=forecast-openrouter-spend.sh
    ...    env=${env}
    ...    secret__openrouter_api_key=${OPENROUTER_API_KEY}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./forecast-openrouter-spend.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat forecast_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for forecast, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Projected spend should remain within the configured budget for the forecast period
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Spend forecast:\n${result.stdout}

Detect OpenRouter Spend Anomalies for Account `${OPENROUTER_API_KEY_LABEL}`
    [Documentation]    Analyzes daily spend totals for statistical outliers using a z-score method. Flags days where spend deviates from the baseline by more than the configured threshold.
    [Tags]    OpenRouter    spend    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=detect-openrouter-spend-anomalies.sh
    ...    env=${env}
    ...    secret__openrouter_api_key=${OPENROUTER_API_KEY}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./detect-openrouter-spend-anomalies.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat anomaly_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for anomaly detection, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Daily spend should not deviate from the baseline by more than the configured anomaly threshold
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Anomaly detection results:\n${result.stdout}


*** Keywords ***
Suite Initialization
    TRY
        ${OPENROUTER_API_KEY}=    RW.Core.Import Secret    OPENROUTER_API_KEY
        ...    type=string
        ...    description=OpenRouter API key for authentication. Bearer token sent in Authorization header.
        ...    pattern=\w*
        Set Suite Variable    ${OPENROUTER_API_KEY}    ${OPENROUTER_API_KEY}
    EXCEPT
        Log    OPENROUTER_API_KEY secret not provided; OpenRouter API tasks will fail until configured.    WARN
        Set Suite Variable    ${OPENROUTER_API_KEY}    ${EMPTY}
    END
    ${OPENROUTER_API_KEY_LABEL}=    RW.Core.Import User Variable    OPENROUTER_API_KEY_LABEL
    ...    type=string
    ...    description=Human-readable label for the OpenRouter API key (e.g. account name or email).
    ...    pattern=.*
    ...    default=openrouter-account
    ${OPENROUTER_LOOKBACK_DAYS}=    RW.Core.Import User Variable    OPENROUTER_LOOKBACK_DAYS
    ...    type=string
    ...    description=Number of days of historical spend to analyze.
    ...    pattern=^\d+$
    ...    default=7
    ${OPENROUTER_BUDGET_USD}=    RW.Core.Import User Variable    OPENROUTER_BUDGET_USD
    ...    type=string
    ...    description=Total budget threshold in USD for the current period. Set to 0 to disable budget checks.
    ...    pattern=^[0-9.]+$
    ...    default=0
    ${OPENROUTER_MIN_BALANCE_USD}=    RW.Core.Import User Variable    OPENROUTER_MIN_BALANCE_USD
    ...    type=string
    ...    description=Minimum remaining balance threshold in USD.
    ...    pattern=^[0-9.]+$
    ...    default=10
    ${OPENROUTER_SPEND_CONCENTRATION_THRESHOLD}=    RW.Core.Import User Variable    OPENROUTER_SPEND_CONCENTRATION_THRESHOLD
    ...    type=string
    ...    description=Maximum percentage of total spend allowed per model before flagging a concentration risk.
    ...    pattern=^\d+(\.\d+)?$
    ...    default=50
    ${OPENROUTER_BALANCE_ALERT_WINDOW_DAYS}=    RW.Core.Import User Variable    OPENROUTER_BALANCE_ALERT_WINDOW_DAYS
    ...    type=string
    ...    description=Days to project forward for balance depletion alerts.
    ...    pattern=^\d+$
    ...    default=7
    ${OPENROUTER_ANOMALY_STDDEV_THRESHOLD}=    RW.Core.Import User Variable    OPENROUTER_ANOMALY_STDDEV_THRESHOLD
    ...    type=string
    ...    description=Number of standard deviations for anomaly detection threshold.
    ...    pattern=^\d+(\.\d+)?$
    ...    default=2
    Set Suite Variable    ${OPENROUTER_API_KEY_LABEL}    ${OPENROUTER_API_KEY_LABEL}
    Set Suite Variable    ${OPENROUTER_LOOKBACK_DAYS}    ${OPENROUTER_LOOKBACK_DAYS}
    Set Suite Variable    ${OPENROUTER_BUDGET_USD}    ${OPENROUTER_BUDGET_USD}
    Set Suite Variable    ${OPENROUTER_MIN_BALANCE_USD}    ${OPENROUTER_MIN_BALANCE_USD}
    Set Suite Variable    ${OPENROUTER_SPEND_CONCENTRATION_THRESHOLD}    ${OPENROUTER_SPEND_CONCENTRATION_THRESHOLD}
    Set Suite Variable    ${OPENROUTER_BALANCE_ALERT_WINDOW_DAYS}    ${OPENROUTER_BALANCE_ALERT_WINDOW_DAYS}
    Set Suite Variable    ${OPENROUTER_ANOMALY_STDDEV_THRESHOLD}    ${OPENROUTER_ANOMALY_STDDEV_THRESHOLD}

    ${env}=    Create Dictionary
    ...    OPENROUTER_API_KEY_LABEL=${OPENROUTER_API_KEY_LABEL}
    ...    OPENROUTER_LOOKBACK_DAYS=${OPENROUTER_LOOKBACK_DAYS}
    ...    OPENROUTER_BUDGET_USD=${OPENROUTER_BUDGET_USD}
    ...    OPENROUTER_MIN_BALANCE_USD=${OPENROUTER_MIN_BALANCE_USD}
    ...    OPENROUTER_SPEND_CONCENTRATION_THRESHOLD=${OPENROUTER_SPEND_CONCENTRATION_THRESHOLD}
    ...    OPENROUTER_BALANCE_ALERT_WINDOW_DAYS=${OPENROUTER_BALANCE_ALERT_WINDOW_DAYS}
    ...    OPENROUTER_ANOMALY_STDDEV_THRESHOLD=${OPENROUTER_ANOMALY_STDDEV_THRESHOLD}
    Set Suite Variable    ${env}    ${env}
