*** Settings ***
Documentation       Pulls Cloudflare firewall and security-adjacent sampled events for a zone via GraphQL Analytics, aggregates them by rule, IP geography, and path, compares configurable thresholds, and renders a consolidated report for proactive abuse detection.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Cloudflare Zone WAF & Security Events Report
Metadata            Supports    Cloudflare    WAF    Firewall    Security    GraphQL    Analytics

Force Tags          Cloudflare    WAF    Firewall    Security    Analytics

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization

*** Tasks ***
Fetch Firewall and WAF Events for Zone `${CLOUDFLARE_ZONE_ID}`
    [Documentation]    Queries Cloudflare GraphQL firewallEventsAdaptive for the primary lookback window (optional prior window for spike math), persists normalized JSON artifacts for downstream aggregation tasks, and surfaces connectivity/schema failures as issues.
    [Tags]    Cloudflare    WAF    firewall    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=fetch-cloudflare-firewall-events.sh
    ...    env=${env}
    ...    secret__cloudflare_api_token=${cloudflare_api_token}
    ...    include_in_history=false
    ...    timeout_seconds=240
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID}" ./fetch-cloudflare-firewall-events.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat cloudflare_waf_fetch_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for fetch task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=GraphQL Analytics should return firewallEventsAdaptive rows or an empty sample without authorization errors
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Firewall/WAF fetch summary (${CLOUDFLARE_ZONE_ID}):\n${result.stdout}

Aggregate WAF Events by Rule, Action, and Service for Zone `${CLOUDFLARE_ZONE_ID}`
    [Documentation]    Reads normalized primary events and groups sampled hits by rule identifier, mitigating action, and protection source so operators see which defenses trigger most often.
    [Tags]    Cloudflare    WAF    aggregate    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=aggregate-waf-by-rule.sh
    ...    env=${env}
    ...    include_in_history=false
    ...    timeout_seconds=120
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./aggregate-waf-by-rule.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat cloudflare_waf_rule_aggregate_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for rule aggregation task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Rule aggregation should parse existing normalized JSON without structural errors
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    WAF rule/action/source aggregation (${CLOUDFLARE_ZONE_ID}):\n${result.stdout}

Correlate WAF Events by Source IP and Country for Zone `${CLOUDFLARE_ZONE_ID}`
    [Documentation]    Builds top-N tables for client IPs, autonomous systems, and countries to differentiate concentrated attacks from widespread noise using sampled firewall rows.
    [Tags]    Cloudflare    WAF    correlate    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=correlate-waf-by-source.sh
    ...    env=${env}
    ...    include_in_history=false
    ...    timeout_seconds=120
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./correlate-waf-by-source.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat cloudflare_waf_source_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for source correlation task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Source correlation should parse normalized JSON successfully
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    WAF IP/ASN/country correlation (${CLOUDFLARE_ZONE_ID}):\n${result.stdout}

Break Down WAF Activity by Hostname and Request Path for Zone `${CLOUDFLARE_ZONE_ID}`
    [Documentation]    Summarizes sampled hits per hostname/path combination when Cloudflare returns host metadata so hotspots can be tuned surgically.
    [Tags]    Cloudflare    WAF    paths    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=aggregate-waf-by-path.sh
    ...    env=${env}
    ...    include_in_history=false
    ...    timeout_seconds=120
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./aggregate-waf-by-path.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat cloudflare_waf_path_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for path aggregation task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Path aggregation should parse normalized JSON successfully
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    WAF hostname/path breakdown (${CLOUDFLARE_ZONE_ID}):\n${result.stdout}

Evaluate WAF Volume and Spike Thresholds for Zone `${CLOUDFLARE_ZONE_ID}`
    [Documentation]    Compares sampled totals and dominant buckets against operator thresholds plus optional primary-vs-prior spike ratios, emitting structured remediation hints when exceeded.
    [Tags]    Cloudflare    WAF    thresholds    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=evaluate-waf-thresholds.sh
    ...    env=${env}
    ...    include_in_history=false
    ...    timeout_seconds=120
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./evaluate-waf-thresholds.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat cloudflare_waf_threshold_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for threshold evaluation task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=WAF sampled volumes should remain below configured operational thresholds during steady-state traffic
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Threshold evaluation (${CLOUDFLARE_ZONE_ID}):\n${result.stdout}

Produce Consolidated WAF Correlation Report for Zone `${CLOUDFLARE_ZONE_ID}`
    [Documentation]    Prints a human-readable rollup referencing upstream aggregation artifacts so incidents can be handed off quickly alongside structured telemetry paths.
    [Tags]    Cloudflare    WAF    report    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=report-waf-correlation-summary.sh
    ...    env=${env}
    ...    include_in_history=false
    ...    timeout_seconds=90
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./report-waf-correlation-summary.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat cloudflare_waf_report_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for consolidated report task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Summary rendering should complete without faults once upstream artifacts exist
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Consolidated report (${CLOUDFLARE_ZONE_ID}):\n${result.stdout}

*** Keywords ***
Suite Initialization
    TRY
        ${cloudflare_api_token}=    RW.Core.Import Secret    cloudflare_api_token
        ...    type=string
        ...    description=Cloudflare API token with Analytics read plus Firewall/WAF scopes for GraphQL queries
        ...    pattern=\w*
        Set Suite Variable    ${cloudflare_api_token}    ${cloudflare_api_token}
    EXCEPT
        Log    cloudflare_api_token secret missing — Cloudflare tasks cannot authenticate until configured.    WARN
        Set Suite Variable    ${cloudflare_api_token}    ${EMPTY}
    END

    ${CLOUDFLARE_ZONE_ID}=    RW.Core.Import User Variable    CLOUDFLARE_ZONE_ID
    ...    type=string
    ...    description=Cloudflare zone identifier (zone tag) scoped for firewall analytics queries.
    ...    pattern=\w+
    ${CLOUDFLARE_ACCOUNT_ID}=    RW.Core.Import User Variable    CLOUDFLARE_ACCOUNT_ID
    ...    type=string
    ...    description=Optional Cloudflare account identifier retained for future dataset filters.
    ...    pattern=^[\w-]*$
    ...    default=
    ${WAF_LOOKBACK_MINUTES}=    RW.Core.Import User Variable    WAF_LOOKBACK_MINUTES
    ...    type=string
    ...    description=Primary analytics window length in minutes.
    ...    pattern=^\d+$
    ...    default=60
    ${WAF_COMPARE_LOOKBACK_MINUTES}=    RW.Core.Import User Variable    WAF_COMPARE_LOOKBACK_MINUTES
    ...    type=string
    ...    description=Minutes for the comparison window immediately before the primary window (0 disables spike ratio logic).
    ...    pattern=^\d+$
    ...    default=60
    ${WAF_TOTAL_EVENTS_ISSUE_THRESHOLD}=    RW.Core.Import User Variable    WAF_TOTAL_EVENTS_ISSUE_THRESHOLD
    ...    type=string
    ...    description=Raise issues when sampled primary-window rows exceed this count.
    ...    pattern=^\d+$
    ...    default=500
    ${WAF_TOP_ENTITY_ISSUE_THRESHOLD}=    RW.Core.Import User Variable    WAF_TOP_ENTITY_ISSUE_THRESHOLD
    ...    type=string
    ...    description=Raise issues when any dominant bucket (rule/path/IP) exceeds this sampled count.
    ...    pattern=^\d+$
    ...    default=100
    ${WAF_SPIKE_RATIO_THRESHOLD}=    RW.Core.Import User Variable    WAF_SPIKE_RATIO_THRESHOLD
    ...    type=string
    ...    description=Minimum primary/prior sampled-count ratio before spike issues emit (0 disables).
    ...    pattern=^\d+(\.\d+)?$
    ...    default=0
    ${WAF_REPORT_TOP_N}=    RW.Core.Import User Variable    WAF_REPORT_TOP_N
    ...    type=string
    ...    description=Top-N entities listed in correlation tables.
    ...    pattern=^\d+$
    ...    default=15
    ${WAF_FETCH_PAGE_LIMIT}=    RW.Core.Import User Variable    WAF_FETCH_PAGE_LIMIT
    ...    type=string
    ...    description=Maximum firewallEventsAdaptive rows requested per GraphQL page while paginating.
    ...    pattern=^\d+$
    ...    default=800
    ${WAF_FETCH_MAX_PAGES}=    RW.Core.Import User Variable    WAF_FETCH_MAX_PAGES
    ...    type=string
    ...    description=Safety cap on pagination iterations for sampled-event retrieval.
    ...    pattern=^\d+$
    ...    default=25

    Set Suite Variable    ${CLOUDFLARE_ZONE_ID}    ${CLOUDFLARE_ZONE_ID}
    Set Suite Variable    ${CLOUDFLARE_ACCOUNT_ID}    ${CLOUDFLARE_ACCOUNT_ID}
    Set Suite Variable    ${WAF_LOOKBACK_MINUTES}    ${WAF_LOOKBACK_MINUTES}
    Set Suite Variable    ${WAF_COMPARE_LOOKBACK_MINUTES}    ${WAF_COMPARE_LOOKBACK_MINUTES}
    Set Suite Variable    ${WAF_TOTAL_EVENTS_ISSUE_THRESHOLD}    ${WAF_TOTAL_EVENTS_ISSUE_THRESHOLD}
    Set Suite Variable    ${WAF_TOP_ENTITY_ISSUE_THRESHOLD}    ${WAF_TOP_ENTITY_ISSUE_THRESHOLD}
    Set Suite Variable    ${WAF_SPIKE_RATIO_THRESHOLD}    ${WAF_SPIKE_RATIO_THRESHOLD}
    Set Suite Variable    ${WAF_REPORT_TOP_N}    ${WAF_REPORT_TOP_N}
    Set Suite Variable    ${WAF_FETCH_PAGE_LIMIT}    ${WAF_FETCH_PAGE_LIMIT}
    Set Suite Variable    ${WAF_FETCH_MAX_PAGES}    ${WAF_FETCH_MAX_PAGES}

    ${env}=    Create Dictionary
    ...    CLOUDFLARE_ZONE_ID=${CLOUDFLARE_ZONE_ID}
    ...    CLOUDFLARE_ACCOUNT_ID=${CLOUDFLARE_ACCOUNT_ID}
    ...    WAF_LOOKBACK_MINUTES=${WAF_LOOKBACK_MINUTES}
    ...    WAF_COMPARE_LOOKBACK_MINUTES=${WAF_COMPARE_LOOKBACK_MINUTES}
    ...    WAF_TOTAL_EVENTS_ISSUE_THRESHOLD=${WAF_TOTAL_EVENTS_ISSUE_THRESHOLD}
    ...    WAF_TOP_ENTITY_ISSUE_THRESHOLD=${WAF_TOP_ENTITY_ISSUE_THRESHOLD}
    ...    WAF_SPIKE_RATIO_THRESHOLD=${WAF_SPIKE_RATIO_THRESHOLD}
    ...    WAF_REPORT_TOP_N=${WAF_REPORT_TOP_N}
    ...    WAF_FETCH_PAGE_LIMIT=${WAF_FETCH_PAGE_LIMIT}
    ...    WAF_FETCH_MAX_PAGES=${WAF_FETCH_MAX_PAGES}
    Set Suite Variable    ${env}    ${env}

    RW.Core.Add Pre To Report    Cloudflare GraphQL reference:\n- Firewall Events tutorial: https://developers.cloudflare.com/analytics/graphql-api/tutorials/querying-firewall-events/\n- Sampling guidance: https://developers.cloudflare.com/analytics/graphql-api/sampling/\n- Token scopes: https://developers.cloudflare.com/analytics/graphql-api/getting-started/authentication/api-token-auth/
