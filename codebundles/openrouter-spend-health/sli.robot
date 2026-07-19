*** Settings ***
Metadata          Author    rw-codebundle-agent
Documentation     Measures OpenRouter API spend health by scoring API reachability, balance sufficiency, account credit availability, budget adherence, anomaly absence, and model concentration risk. Produces a value between 0 (completely failing) and 1 (fully passing).
Metadata          Display Name    OpenRouter Spend Health and Forecasting
Metadata          Supports    OpenRouter    spend    health    forecasting
Suite Setup       Suite Initialization
Library           BuiltIn
Library           String
Library           RW.Core
Library           RW.CLI
Library           RW.platform


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
    ...    description=Human-readable label for the OpenRouter API key.
    ...    pattern=.*
    ...    default=openrouter-account
    ${OPENROUTER_LOOKBACK_DAYS}=    RW.Core.Import User Variable    OPENROUTER_LOOKBACK_DAYS
    ...    type=string
    ...    description=Number of days of historical spend to analyze.
    ...    pattern=^\d+$
    ...    default=7
    ${OPENROUTER_BUDGET_USD}=    RW.Core.Import User Variable    OPENROUTER_BUDGET_USD
    ...    type=string
    ...    description=Total budget threshold in USD. 0 disables budget scoring.
    ...    pattern=^[0-9.]+$
    ...    default=0
    ${OPENROUTER_MIN_BALANCE_USD}=    RW.Core.Import User Variable    OPENROUTER_MIN_BALANCE_USD
    ...    type=string
    ...    description=Minimum remaining balance threshold in USD.
    ...    pattern=^[0-9.]+$
    ...    default=10
    ${OPENROUTER_SPEND_CONCENTRATION_THRESHOLD}=    RW.Core.Import User Variable    OPENROUTER_SPEND_CONCENTRATION_THRESHOLD
    ...    type=string
    ...    description=Maximum percentage of total spend allowed per model.
    ...    pattern=^\d+(\.\d+)?$
    ...    default=50
    ${OPENROUTER_ANOMALY_STDDEV_THRESHOLD}=    RW.Core.Import User Variable    OPENROUTER_ANOMALY_STDDEV_THRESHOLD
    ...    type=string
    ...    description=Number of standard deviations for anomaly detection.
    ...    pattern=^\d+(\.\d+)?$
    ...    default=2

    Set Suite Variable    ${OPENROUTER_API_KEY_LABEL}    ${OPENROUTER_API_KEY_LABEL}
    Set Suite Variable    ${OPENROUTER_LOOKBACK_DAYS}    ${OPENROUTER_LOOKBACK_DAYS}
    Set Suite Variable    ${OPENROUTER_BUDGET_USD}    ${OPENROUTER_BUDGET_USD}
    Set Suite Variable    ${OPENROUTER_MIN_BALANCE_USD}    ${OPENROUTER_MIN_BALANCE_USD}
    Set Suite Variable    ${OPENROUTER_SPEND_CONCENTRATION_THRESHOLD}    ${OPENROUTER_SPEND_CONCENTRATION_THRESHOLD}
    Set Suite Variable    ${OPENROUTER_ANOMALY_STDDEV_THRESHOLD}    ${OPENROUTER_ANOMALY_STDDEV_THRESHOLD}

    ${env}=    Create Dictionary
    ...    OPENROUTER_API_KEY_LABEL=${OPENROUTER_API_KEY_LABEL}
    ...    OPENROUTER_LOOKBACK_DAYS=${OPENROUTER_LOOKBACK_DAYS}
    ...    OPENROUTER_BUDGET_USD=${OPENROUTER_BUDGET_USD}
    ...    OPENROUTER_MIN_BALANCE_USD=${OPENROUTER_MIN_BALANCE_USD}
    ...    OPENROUTER_SPEND_CONCENTRATION_THRESHOLD=${OPENROUTER_SPEND_CONCENTRATION_THRESHOLD}
    ...    OPENROUTER_ANOMALY_STDDEV_THRESHOLD=${OPENROUTER_ANOMALY_STDDEV_THRESHOLD}
    Set Suite Variable    ${env}    ${env}


*** Tasks ***
Score API Reachability for `${OPENROUTER_API_KEY_LABEL}`
    [Documentation]    Binary 1 if the OpenRouter /api/v1/key endpoint returns a valid response within timeout.
    [Tags]    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Cli
    ...    cmd=curl -s --max-time 15 -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${openrouter_api_key}" "https://openrouter.ai/api/v1/key"
    ...    env=${env}
    ...    timeout_seconds=30
    ${http_code}=    Strip String    ${result.stdout}
    ${score}=    Evaluate    1 if ${http_code} == 200 else 0
    Set Suite Variable    ${score_api}    ${score}
    RW.Core.Push Metric    ${score}    sub_name=api_reachable

Score Balance Sufficiency for `${OPENROUTER_API_KEY_LABEL}`
    [Documentation]    Binary 1 if remaining account balance is above the minimum threshold.
    [Tags]    access:read-only    data:config
    ${result}=    RW.CLI.Run Cli
    ...    cmd=curl -s --max-time 15 -H "Authorization: Bearer ${openrouter_api_key}" "https://openrouter.ai/api/v1/key" | jq -r '.data.limit_remaining // "0"'
    ...    env=${env}
    ...    timeout_seconds=30
    TRY
        ${credits}=    Convert To Number    ${result.stdout}
        ${min_balance}=    Convert To Number    ${OPENROUTER_MIN_BALANCE_USD}
        ${score}=    Evaluate    1 if ${credits} >= ${min_balance} else 0
    EXCEPT
        Log    Failed to parse balance. Defaulting to score 0.    WARN
        ${score}=    Set Variable    0
    END
    Set Suite Variable    ${score_balance}    ${score}
    RW.Core.Push Metric    ${score}    sub_name=balance_sufficient

Score Credit Availability for `${OPENROUTER_API_KEY_LABEL}`
    [Documentation]    Binary 1 if account-level credits are available (using /credits for management keys via the balance script, or key limits fallback), otherwise 0.
    [Tags]    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-openrouter-balance.sh
    ...    env=${env}
    ...    secret__openrouter_api_key=${openrouter_api_key}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./check-openrouter-balance.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat balance_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        ${credit_issue_count}=    Evaluate    len([i for i in ${issue_list} if i.get('title') in ['OpenRouter Account Balance Low', 'OpenRouter Remaining Credits Not Reported']])
        ${score}=    Evaluate    1 if ${credit_issue_count} == 0 else 0
    EXCEPT
        Log    Failed to parse balance JSON for credit availability score. Defaulting to score 0.    WARN
        ${score}=    Set Variable    0
    END
    Set Suite Variable    ${score_credit_availability}    ${score}
    RW.Core.Push Metric    ${score}    sub_name=credit_available

Score Budget Adherence for `${OPENROUTER_API_KEY_LABEL}`
    [Documentation]    Binary 1 if budget is disabled (0) or cumulative spend is under the configured budget.
    [Tags]    access:read-only    data:config
    ${budget}=    Convert To Number    ${OPENROUTER_BUDGET_USD}
    IF    ${budget} == 0
        ${score}=    Set Variable    1
    ELSE
        ${result}=    RW.CLI.Run Cli
        ...    cmd=curl -s --max-time 15 -H "Authorization: Bearer ${openrouter_api_key}" "https://openrouter.ai/api/v1/key" | jq -r '.data.usage_monthly // .data.usage // "0"'
        ...    env=${env}
        ...    timeout_seconds=30
        TRY
            ${usage}=    Convert To Number    ${result.stdout}
            ${score}=    Evaluate    1 if ${usage} <= ${budget} else 0
        EXCEPT
            Log    Failed to parse usage. Defaulting to score 0.    WARN
            ${score}=    Set Variable    0
        END
    END
    Set Suite Variable    ${score_budget}    ${score}
    RW.Core.Push Metric    ${score}    sub_name=budget_adherent

Score Anomaly Status for `${OPENROUTER_API_KEY_LABEL}`
    [Documentation]    Binary 1 if no spend anomalies (spikes or acceleration) are detected in the lookback window.
    [Tags]    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=detect-openrouter-spend-anomalies.sh
    ...    env=${env}
    ...    secret__openrouter_api_key=${openrouter_api_key}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./detect-openrouter-spend-anomalies.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat anomaly_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        ${anomaly_count}=    Get Length    ${issue_list}
        ${score}=    Evaluate    1 if ${anomaly_count} == 0 else 0
    EXCEPT
        Log    Failed to parse anomaly JSON. Defaulting to score 0.    WARN
        ${score}=    Set Variable    0
    END
    Set Suite Variable    ${score_anomaly}    ${score}
    RW.Core.Push Metric    ${score}    sub_name=no_anomalies

Score Model Concentration for `${OPENROUTER_API_KEY_LABEL}`
    [Documentation]    Binary 1 if no single model exceeds the configured concentration threshold.
    [Tags]    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze-openrouter-spend-by-model.sh
    ...    env=${env}
    ...    secret__openrouter_api_key=${openrouter_api_key}
    ...    timeout_seconds=120
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./analyze-openrouter-spend-by-model.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat model_spend_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        ${concentration_count}=    Get Length    ${issue_list}
        ${score}=    Evaluate    1 if ${concentration_count} == 0 else 0
    EXCEPT
        Log    Failed to parse model spend JSON. Defaulting to score 0.    WARN
        ${score}=    Set Variable    0
    END
    Set Suite Variable    ${score_concentration}    ${score}
    RW.Core.Push Metric    ${score}    sub_name=model_concentration_ok

Generate OpenRouter Spend Health Score for `${OPENROUTER_API_KEY_LABEL}`
    [Documentation]    Averages sub-scores (API reachable, balance sufficient, credit available, budget adherent, no anomalies, model concentration ok) into the final 0-1 metric for alerting.
    [Tags]    access:read-only    data:metrics
    ${health_score}=    Evaluate    (${score_api} + ${score_balance} + ${score_credit_availability} + ${score_budget} + ${score_anomaly} + ${score_concentration}) / 6
    ${health_score}=    Convert to Number    ${health_score}    2
    RW.Core.Add to Report    OpenRouter spend health score: ${health_score}
    RW.Core.Push Metric    ${health_score}