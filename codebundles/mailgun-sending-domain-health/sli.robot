*** Settings ***
Documentation       Measures Mailgun sending domain health from domain state, delivery success, and SPF alignment. Produces a score between 0 and 1.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Mailgun Sending Domain Health SLI
Metadata            Supports    Mailgun    email    DNS    delivery

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization

*** Keywords ***
Suite Initialization
    TRY
        ${mailgun_api_key}=    RW.Core.Import Secret    mailgun_api_key
        ...    type=string
        ...    description=Mailgun private API key (HTTP Basic user=api, password=key)
        ...    pattern=\w*
        Set Suite Variable    ${mailgun_api_key}    ${mailgun_api_key}
    EXCEPT
        Log    mailgun_api_key secret not found.    WARN
        Set Suite Variable    ${mailgun_api_key}    ${EMPTY}
    END

    ${MAILGUN_SENDING_DOMAIN}=    RW.Core.Import User Variable    MAILGUN_SENDING_DOMAIN
    ...    type=string
    ...    description=FQDN of the Mailgun sending domain to assess.
    ...    pattern=^[a-zA-Z0-9.-]+$
    ${MAILGUN_API_REGION}=    RW.Core.Import User Variable    MAILGUN_API_REGION
    ...    type=string
    ...    description=Mailgun API region (us or eu).
    ...    pattern=^(us|eu|US|EU)$
    ${MAILGUN_STATS_WINDOW_HOURS}=    RW.Core.Import User Variable    MAILGUN_STATS_WINDOW_HOURS
    ...    type=string
    ...    description=Rolling window in hours for Mailgun stats queries.
    ...    pattern=^\d+$
    ...    default=24
    ${MAILGUN_MIN_DELIVERY_SUCCESS_PCT}=    RW.Core.Import User Variable    MAILGUN_MIN_DELIVERY_SUCCESS_PCT
    ...    type=string
    ...    description=Minimum acceptable delivery success percentage for SLI scoring.
    ...    pattern=^[0-9.]+$
    ...    default=95
    ${MAILGUN_VOLUME_DROP_THRESHOLD_PCT}=    RW.Core.Import User Variable    MAILGUN_VOLUME_DROP_THRESHOLD_PCT
    ...    type=string
    ...    description=Week-over-week volume decline percentage that triggers SLI score 0 (e.g. 80 means 80%+ drop).
    ...    pattern=^[0-9.]+$
    ...    default=80

    ${env}=    Create Dictionary
    ...    MAILGUN_SENDING_DOMAIN=${MAILGUN_SENDING_DOMAIN}
    ...    MAILGUN_API_REGION=${MAILGUN_API_REGION}
    ...    MAILGUN_STATS_WINDOW_HOURS=${MAILGUN_STATS_WINDOW_HOURS}
    ...    MAILGUN_MIN_DELIVERY_SUCCESS_PCT=${MAILGUN_MIN_DELIVERY_SUCCESS_PCT}
    ...    MAILGUN_VOLUME_DROP_THRESHOLD_PCT=${MAILGUN_VOLUME_DROP_THRESHOLD_PCT}
    Set Suite Variable    ${env}    ${env}
    Set Suite Variable    ${score_domain}    0
    Set Suite Variable    ${score_delivery}    0
    Set Suite Variable    ${score_spf}    0
    Set Suite Variable    ${score_volume}    0

*** Tasks ***
Score Mailgun Domain Active State
    [Documentation]    Binary 1/0 score from Mailgun Domains API active state.
    [Tags]    Mailgun    email    sli    access:read-only    data:metrics
    ${out}=    RW.CLI.Run Bash File
    ...    bash_file=sli-mailgun-domain-score.sh
    ...    env=${env}
    ...    secret__mailgun_api_key=${mailgun_api_key}
    ...    include_in_history=false
    ...    timeout_seconds=60
    TRY
        ${data}=    Evaluate    json.loads(r'''${out.stdout}''')    json
    EXCEPT
        Log    SLI domain JSON parse failed; scoring 0.    WARN
        ${data}=    Create Dictionary    score=0
    END
    ${s}=    Set Variable    ${data.get('score', 0)}
    Set Suite Variable    ${score_domain}    ${s}
    RW.Core.Push Metric    ${s}    sub_name=domain_active

Score Mailgun Delivery Success Threshold
    [Documentation]    Binary 1/0 score comparing delivery success to MAILGUN_MIN_DELIVERY_SUCCESS_PCT.
    [Tags]    Mailgun    email    sli    access:read-only    data:metrics
    ${out}=    RW.CLI.Run Bash File
    ...    bash_file=sli-mailgun-delivery-score.sh
    ...    env=${env}
    ...    secret__mailgun_api_key=${mailgun_api_key}
    ...    include_in_history=false
    ...    timeout_seconds=90
    TRY
        ${data}=    Evaluate    json.loads(r'''${out.stdout}''')    json
    EXCEPT
        Log    SLI delivery JSON parse failed; scoring 0.    WARN
        ${data}=    Create Dictionary    score=0
    END
    ${s}=    Set Variable    ${data.get('score', 0)}
    Set Suite Variable    ${score_delivery}    ${s}
    RW.Core.Push Metric    ${s}    sub_name=delivery_success

Score Mailgun SPF Alignment
    [Documentation]    Binary 1/0 score when SPF authorizes Mailgun.
    [Tags]    Mailgun    email    sli    access:read-only    data:metrics
    ${out}=    RW.CLI.Run Bash File
    ...    bash_file=sli-mailgun-spf-score.sh
    ...    env=${env}
    ...    include_in_history=false
    ...    timeout_seconds=45
    TRY
        ${data}=    Evaluate    json.loads(r'''${out.stdout}''')    json
    EXCEPT
        Log    SLI SPF JSON parse failed; scoring 0.    WARN
        ${data}=    Create Dictionary    score=0
    END
    ${s}=    Set Variable    ${data.get('score', 0)}
    Set Suite Variable    ${score_spf}    ${s}
    RW.Core.Push Metric    ${s}    sub_name=spf_mailgun

Score Mailgun Volume Trend
    [Documentation]    Binary 1/0 score comparing current-week volume to 30-day historical weekly average.
    [Tags]    Mailgun    email    sli    access:read-only    data:metrics
    ${out}=    RW.CLI.Run Bash File
    ...    bash_file=sli-mailgun-volume-trend-score.sh
    ...    env=${env}
    ...    secret__mailgun_api_key=${mailgun_api_key}
    ...    include_in_history=false
    ...    timeout_seconds=90
    TRY
        ${data}=    Evaluate    json.loads(r'''${out.stdout}''')    json
    EXCEPT
        Log    SLI volume trend JSON parse failed; scoring 0.    WARN
        ${data}=    Create Dictionary    score=0
    END
    ${s}=    Set Variable    ${data.get('score', 0)}
    Set Suite Variable    ${score_volume}    ${s}
    RW.Core.Push Metric    ${s}    sub_name=volume_trend

Generate Aggregate Mailgun Domain Health Score
    [Documentation]    Averages binary sub-scores into the primary 0-1 SLI metric.
    [Tags]    Mailgun    email    sli    access:read-only    data:metrics
    ${health_score}=    Evaluate    (int(${score_domain}) + int(${score_delivery}) + int(${score_spf}) + int(${score_volume})) / 4.0
    ${health_score}=    Convert To Number    ${health_score}    2
    ${report_line}=    Set Variable    Mailgun domain health score: ${health_score} [domain\=${score_domain}, delivery\=${score_delivery}, spf\=${score_spf}, volume_trend\=${score_volume}]
    RW.Core.Add to Report    ${report_line}
    RW.Core.Push Metric    ${health_score}
