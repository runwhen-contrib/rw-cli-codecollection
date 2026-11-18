*** Settings ***
Documentation       Measures Cloudflare zone WAF GraphQL reachability and sampled-event intensity across two binary dimensions then averages them into a 0–1 score aligned with the zone firewall analytics bundle thresholds.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Cloudflare Zone WAF Quick Score SLI
Metadata            Supports    Cloudflare    WAF    Analytics    SLI

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization

*** Keywords ***
Suite Initialization
    TRY
        ${cloudflare_api_token}=    RW.Core.Import Secret    cloudflare_api_token
        ...    type=string
        ...    description=Cloudflare API token with Analytics read scope for lightweight firewall sampling.
        ...    pattern=\w*
        Set Suite Variable    ${cloudflare_api_token}    ${cloudflare_api_token}
    EXCEPT
        Log    cloudflare_api_token secret missing — SLI will score zero until configured.    WARN
        Set Suite Variable    ${cloudflare_api_token}    ${EMPTY}
    END

    ${CLOUDFLARE_ZONE_ID}=    RW.Core.Import User Variable    CLOUDFLARE_ZONE_ID
    ...    type=string
    ...    description=Cloudflare zone tag targeted by GraphQL analytics probes.
    ...    pattern=\w+
    ${SLI_WAF_LOOKBACK_MINUTES}=    RW.Core.Import User Variable    SLI_WAF_LOOKBACK_MINUTES
    ...    type=string
    ...    description=Short lookback window for SLI sampling (keep <=15 minutes for sub-30s runtime).
    ...    pattern=^\d+$
    ...    default=15
    ${SLI_WAF_MAX_SAMPLE_ROWS}=    RW.Core.Import User Variable    SLI_WAF_MAX_SAMPLE_ROWS
    ...    type=string
    ...    description=Maximum rows pulled during SLI GraphQL probe (bounds latency).
    ...    pattern=^\d+$
    ...    default=400
    ${SLI_WAF_MAX_EVENTS}=    RW.Core.Import User Variable    SLI_WAF_MAX_EVENTS
    ...    type=string
    ...    description=Maximum acceptable sampled hits inside SLI window before volume sub-score fails.
    ...    pattern=^\d+$
    ...    default=250

    Set Suite Variable    ${CLOUDFLARE_ZONE_ID}    ${CLOUDFLARE_ZONE_ID}
    Set Suite Variable    ${SLI_WAF_LOOKBACK_MINUTES}    ${SLI_WAF_LOOKBACK_MINUTES}
    Set Suite Variable    ${SLI_WAF_MAX_SAMPLE_ROWS}    ${SLI_WAF_MAX_SAMPLE_ROWS}
    Set Suite Variable    ${SLI_WAF_MAX_EVENTS}    ${SLI_WAF_MAX_EVENTS}

    ${env}=    Create Dictionary
    ...    CLOUDFLARE_ZONE_ID=${CLOUDFLARE_ZONE_ID}
    ...    SLI_WAF_LOOKBACK_MINUTES=${SLI_WAF_LOOKBACK_MINUTES}
    ...    SLI_WAF_MAX_SAMPLE_ROWS=${SLI_WAF_MAX_SAMPLE_ROWS}
    ...    SLI_WAF_MAX_EVENTS=${SLI_WAF_MAX_EVENTS}
    Set Suite Variable    ${env}    ${env}

    Set Suite Variable    ${score_api}    0
    Set Suite Variable    ${score_volume}    0

*** Tasks ***
Score Cloudflare GraphQL Firewall Sampling Reachability
    [Documentation]    Runs the bundled bash probe against firewallEventsAdaptive to verify credentials and schema compatibility before averaging scores.
    [Tags]    Cloudflare    WAF    sli    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sli-cloudflare-waf-score.sh
    ...    env=${env}
    ...    secret__cloudflare_api_token=${cloudflare_api_token}
    ...    include_in_history=false
    ...    timeout_seconds=60
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./sli-cloudflare-waf-score.sh

    TRY
        ${payload}=    Evaluate    json.loads(r'''${result.stdout}''')    json
        ${api}=    Evaluate    int(${payload}.get('api_ok') or 0)
        ${vol}=    Evaluate    int(${payload}.get('volume_ok') or 0)
        ${rows}=    Evaluate    int(${payload}.get('primary_rows') or 0)
    EXCEPT
        Log    Failed to parse SLI probe JSON — defaulting scores to zero.    WARN
        ${api}=    Set Variable    0
        ${vol}=    Set Variable    0
        ${rows}=    Set Variable    0
    END

    Set Suite Variable    ${score_api}    ${api}
    Set Suite Variable    ${score_volume}    ${vol}

    RW.Core.Push Metric    ${api}    sub_name=waf_graphql_ok
    RW.Core.Push Metric    ${vol}    sub_name=waf_volume_ok
    RW.Core.Add To Report    SLI probe rows=${rows}; api_ok=${api}; volume_ok=${vol}

Generate Aggregate Cloudflare WAF SLI Score
    [Documentation]    Averages API reachability and sampled-volume binary scores into the aggregate SLI metric expected by the platform (mean of two dimensions).
    [Tags]    Cloudflare    WAF    sli    access:read-only    data:metrics

    ${health_score}=    Evaluate    (${score_api} + ${score_volume}) / 2.0
    ${health_score}=    Convert To Number    ${health_score}    2
    RW.Core.Add To Report    Cloudflare WAF SLI score: ${health_score} (api=${score_api}, volume=${score_volume})
    RW.Core.Push Metric    ${health_score}
