*** Settings ***
Documentation       Measures Mailgun platform health from public status APIs and unauthenticated regional API probes. Produces a value between 0 (failing) and 1 (healthy).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Mailgun Platform Status SLI
Metadata            Supports    Mailgun network_service platform-status
Force Tags          Mailgun    network_service    platform-status

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Score Mailgun Platform Health for Region Focus `${MAILGUN_STATUS_REGION_FOCUS}`
    [Documentation]    Runs lightweight curl checks for status green, zero unresolved incidents, and expected 401 JSON responses on regional API bases. Aggregates binary scores into a 0-1 metric.
    [Tags]    mailgun    platform    sli    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sli-mailgun-platform-score.sh
    ...    env=${env}
    ...    timeout_seconds=25
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=MAILGUN_STATUS_REGION_FOCUS="${MAILGUN_STATUS_REGION_FOCUS}" ./sli-mailgun-platform-score.sh

    TRY
        ${d}=    Evaluate    json.loads(r'''${result.stdout}''')    json
    EXCEPT
        Log    Failed to parse SLI JSON, scoring 0.    WARN
        ${d}=    Evaluate    {"page": 0, "health_score": 0, "us_included": False, "eu_included": False}    json
    END

    ${page}=    Evaluate    float($d['page'])
    RW.Core.Push Metric    ${page}    sub_name=page

    ${inc_us}=    Evaluate    $d.get('us_included')    json
    IF    ${inc_us}
        ${us}=    Evaluate    float($d['us'])
        RW.Core.Push Metric    ${us}    sub_name=us_api
    END

    ${inc_eu}=    Evaluate    $d.get('eu_included')    json
    IF    ${inc_eu}
        ${eu}=    Evaluate    float($d['eu'])
        RW.Core.Push Metric    ${eu}    sub_name=eu_api
    END

    ${health}=    Evaluate    float($d['health_score'])
    RW.Core.Add to Report    Mailgun platform health score: ${health}
    RW.Core.Push Metric    ${health}


*** Keywords ***
Suite Initialization
    ${MAILGUN_STATUS_REGION_FOCUS}=    RW.Core.Import User Variable    MAILGUN_STATUS_REGION_FOCUS
    ...    type=string
    ...    description=Which regional reachability checks matter: us, eu, or both.
    ...    pattern=\w*
    ...    default=both
    ...    enum=[us,eu,both]
    ${MAILGUN_STATUS_LOOKBACK_HOURS}=    RW.Core.Import User Variable    MAILGUN_STATUS_LOOKBACK_HOURS
    ...    type=string
    ...    description=Hours of incident history (reserved for parity with runbook; SLI uses live status only).
    ...    pattern=^\d+$
    ...    default=24

    Set Suite Variable    ${MAILGUN_STATUS_REGION_FOCUS}    ${MAILGUN_STATUS_REGION_FOCUS}
    Set Suite Variable    ${MAILGUN_STATUS_LOOKBACK_HOURS}    ${MAILGUN_STATUS_LOOKBACK_HOURS}

    ${env_dict}=    Create Dictionary
    ...    MAILGUN_STATUS_REGION_FOCUS=${MAILGUN_STATUS_REGION_FOCUS}
    ...    MAILGUN_STATUS_LOOKBACK_HOURS=${MAILGUN_STATUS_LOOKBACK_HOURS}
    Set Suite Variable    ${env}    ${env_dict}
