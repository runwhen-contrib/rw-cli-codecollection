*** Settings ***
Documentation       Validates Mailgun sending domain verification state, delivery metrics, and DNS (SPF, DKIM, DMARC, optional MX) for the configured region.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Mailgun Sending Domain Delivery & DNS Health
Metadata            Supports    Mailgun    email    DNS    delivery    domain

Force Tags          Mailgun    email    delivery    domain    health

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             Collections

Suite Setup         Suite Initialization

*** Tasks ***
Validate Mailgun Domain Scope Configuration
    [Documentation]    Confirms at least one Mailgun sending domain is in scope before running deeper checks.
    [Tags]    Mailgun    email    domain    access:read-only    data:config

    ${n}=    Get Length    ${DOMAIN_LIST}
    RW.Core.Add Pre To Report    Mailgun domain scope (count=${n}): ${DOMAIN_LIST}
    IF    ${n} == 0
        RW.Core.Add Issue
        ...    severity=4
        ...    expected=At least one Mailgun sending domain should be in scope
        ...    actual=No domains resolved from RESOURCES=All discovery or RESOURCES override
        ...    title=No Mailgun Sending Domains In Scope
        ...    reproduce_hint=RESOURCES=All ./discover-mailgun-domains.sh
        ...    details=Configure RESOURCES to a domain FQDN or use RESOURCES=All with a valid mailgun_api_key to list domains.
        ...    next_steps=Set MAILGUN_SENDING_DOMAIN and RESOURCES per workspace docs; verify API key and MAILGUN_API_REGION.
    END

Verify Mailgun Domain Registration and State for Domains in Scope
    [Documentation]    Calls Mailgun Domains API to confirm each domain exists, is active, and required DNS records are verified.
    [Tags]    Mailgun    email    domain    access:read-only    data:logs-config

    FOR    ${DOMAIN}    IN    @{DOMAIN_LIST}
        ${env_d}=    Copy Dictionary    ${env}
        Set To Dictionary    ${env_d}    MAILGUN_SENDING_DOMAIN    ${DOMAIN}
        ${result}=    RW.CLI.Run Bash File
        ...    bash_file=check-mailgun-domain-state.sh
        ...    env=${env_d}
        ...    secret__mailgun_api_key=${mailgun_api_key}
        ...    include_in_history=false
        ...    timeout_seconds=180
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=MAILGUN_SENDING_DOMAIN="${DOMAIN}" ./check-mailgun-domain-state.sh
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat mailgun_domain_state_issues.json
        ...    timeout_seconds=30
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        EXCEPT
            Log    Failed to parse JSON for domain state task, defaulting to empty list.    WARN
            ${issue_list}=    Create List
        END
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=Mailgun domain should be active with required DNS records verified
                ...    actual=${issue['details']}
                ...    title=${issue['title']}
                ...    reproduce_hint=${result.cmd}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_steps']}
            END
        END
        RW.Core.Add Pre To Report    Domain state (${DOMAIN}):\n${result.stdout}
    END

Check Delivery Success Rate for Mailgun Domains in Scope
    [Documentation]    Aggregates delivered vs failed stats over MAILGUN_STATS_WINDOW_HOURS and compares to MAILGUN_MIN_DELIVERY_SUCCESS_PCT.
    [Tags]    Mailgun    email    metrics    delivery    access:read-only    data:metrics

    FOR    ${DOMAIN}    IN    @{DOMAIN_LIST}
        ${env_d}=    Copy Dictionary    ${env}
        Set To Dictionary    ${env_d}    MAILGUN_SENDING_DOMAIN    ${DOMAIN}
        ${result}=    RW.CLI.Run Bash File
        ...    bash_file=check-mailgun-delivery-success-rate.sh
        ...    env=${env_d}
        ...    secret__mailgun_api_key=${mailgun_api_key}
        ...    include_in_history=false
        ...    timeout_seconds=180
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=MAILGUN_SENDING_DOMAIN="${DOMAIN}" ./check-mailgun-delivery-success-rate.sh
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat mailgun_delivery_success_issues.json
        ...    timeout_seconds=30
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        EXCEPT
            Log    Failed to parse JSON for delivery task, defaulting to empty list.    WARN
            ${issue_list}=    Create List
        END
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=Delivery success rate should meet the configured minimum
                ...    actual=${issue['details']}
                ...    title=${issue['title']}
                ...    reproduce_hint=${result.cmd}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_steps']}
            END
        END
        RW.Core.Add Pre To Report    Delivery stats (${DOMAIN}):\n${result.stdout}
    END

Check Bounce and Complaint Rates for Mailgun Domains in Scope
    [Documentation]    Evaluates bounce and complaint ratios from Mailgun stats against MAILGUN_MAX_BOUNCE_RATE_PCT and MAILGUN_MAX_COMPLAINT_RATE_PCT.
    [Tags]    Mailgun    email    metrics    reputation    access:read-only    data:metrics

    FOR    ${DOMAIN}    IN    @{DOMAIN_LIST}
        ${env_d}=    Copy Dictionary    ${env}
        Set To Dictionary    ${env_d}    MAILGUN_SENDING_DOMAIN    ${DOMAIN}
        ${result}=    RW.CLI.Run Bash File
        ...    bash_file=check-mailgun-bounce-complaint-rates.sh
        ...    env=${env_d}
        ...    secret__mailgun_api_key=${mailgun_api_key}
        ...    include_in_history=false
        ...    timeout_seconds=180
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=MAILGUN_SENDING_DOMAIN="${DOMAIN}" ./check-mailgun-bounce-complaint-rates.sh
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat mailgun_bounce_complaint_issues.json
        ...    timeout_seconds=30
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        EXCEPT
            Log    Failed to parse JSON for bounce/complaint task, defaulting to empty list.    WARN
            ${issue_list}=    Create List
        END
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=Bounce and complaint rates should stay below configured thresholds
                ...    actual=${issue['details']}
                ...    title=${issue['title']}
                ...    reproduce_hint=${result.cmd}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_steps']}
            END
        END
        RW.Core.Add Pre To Report    Bounce/complaint (${DOMAIN}):\n${result.stdout}
    END

Sample Recent Delivered Messages for Mailgun Domains in Scope
    [Documentation]    Retrieves a sample of recently delivered messages showing recipients, subjects, and delivery details.
    [Tags]    Mailgun    email    events    delivery    access:read-only    data:logs-config

    FOR    ${DOMAIN}    IN    @{DOMAIN_LIST}
        ${env_d}=    Copy Dictionary    ${env}
        Set To Dictionary    ${env_d}    MAILGUN_SENDING_DOMAIN    ${DOMAIN}
        ${result}=    RW.CLI.Run Bash File
        ...    bash_file=sample-mailgun-delivered.sh
        ...    env=${env_d}
        ...    secret__mailgun_api_key=${mailgun_api_key}
        ...    include_in_history=false
        ...    timeout_seconds=180
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=MAILGUN_SENDING_DOMAIN="${DOMAIN}" ./sample-mailgun-delivered.sh
        RW.Core.Add Pre To Report    Delivered sample (${DOMAIN}):\n${result.stdout}
    END

Analyze 30-Day Volume Trends for Mailgun Domains in Scope
    [Documentation]    Fetches 30 days of daily metrics, compares week-over-week volume, and flags cliff drops exceeding MAILGUN_VOLUME_DROP_THRESHOLD_PCT.
    [Tags]    Mailgun    email    metrics    trends    access:read-only    data:metrics

    FOR    ${DOMAIN}    IN    @{DOMAIN_LIST}
        ${env_d}=    Copy Dictionary    ${env}
        Set To Dictionary    ${env_d}    MAILGUN_SENDING_DOMAIN    ${DOMAIN}
        ${result}=    RW.CLI.Run Bash File
        ...    bash_file=check-mailgun-volume-trends.sh
        ...    env=${env_d}
        ...    secret__mailgun_api_key=${mailgun_api_key}
        ...    include_in_history=false
        ...    timeout_seconds=180
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=MAILGUN_SENDING_DOMAIN="${DOMAIN}" ./check-mailgun-volume-trends.sh
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat mailgun_volume_trend_issues.json
        ...    timeout_seconds=30
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        EXCEPT
            Log    Failed to parse JSON for volume trend task, defaulting to empty list.    WARN
            ${issue_list}=    Create List
        END
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=Email volume should remain consistent week-over-week without sudden drops
                ...    actual=${issue['details']}
                ...    title=${issue['title']}
                ...    reproduce_hint=${result.cmd}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_steps']}
            END
        END
        RW.Core.Add Pre To Report    Volume trends (${DOMAIN}):\n${result.stdout}
    END

Check Recent Permanent Failures in Mailgun Events for Domains in Scope
    [Documentation]    Samples recent failed events to surface DNS, policy, or authentication-related failures.
    [Tags]    Mailgun    email    events    failures    access:read-only    data:logs-config

    FOR    ${DOMAIN}    IN    @{DOMAIN_LIST}
        ${env_d}=    Copy Dictionary    ${env}
        Set To Dictionary    ${env_d}    MAILGUN_SENDING_DOMAIN    ${DOMAIN}
        ${result}=    RW.CLI.Run Bash File
        ...    bash_file=check-mailgun-recent-failures.sh
        ...    env=${env_d}
        ...    secret__mailgun_api_key=${mailgun_api_key}
        ...    include_in_history=false
        ...    timeout_seconds=180
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=MAILGUN_SENDING_DOMAIN="${DOMAIN}" ./check-mailgun-recent-failures.sh
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat mailgun_recent_failures_issues.json
        ...    timeout_seconds=30
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        EXCEPT
            Log    Failed to parse JSON for events task, defaulting to empty list.    WARN
            ${issue_list}=    Create List
        END
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=No unexpected permanent failures in the recent Mailgun event window
                ...    actual=${issue['details']}
                ...    title=${issue['title']}
                ...    reproduce_hint=${result.cmd}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_steps']}
            END
        END
        RW.Core.Add Pre To Report    Recent failures (${DOMAIN}):\n${result.stdout}
    END

Check for Rejected Messages in Mailgun for Domains in Scope
    [Documentation]    Samples messages Mailgun refused to process (suppressions, policy blocks, invalid recipients) to diagnose volume drops.
    [Tags]    Mailgun    email    events    rejected    access:read-only    data:logs-config

    FOR    ${DOMAIN}    IN    @{DOMAIN_LIST}
        ${env_d}=    Copy Dictionary    ${env}
        Set To Dictionary    ${env_d}    MAILGUN_SENDING_DOMAIN    ${DOMAIN}
        ${result}=    RW.CLI.Run Bash File
        ...    bash_file=check-mailgun-rejected-events.sh
        ...    env=${env_d}
        ...    secret__mailgun_api_key=${mailgun_api_key}
        ...    include_in_history=false
        ...    timeout_seconds=180
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=MAILGUN_SENDING_DOMAIN="${DOMAIN}" ./check-mailgun-rejected-events.sh
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat mailgun_rejected_events_issues.json
        ...    timeout_seconds=30
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        EXCEPT
            Log    Failed to parse JSON for rejected events task, defaulting to empty list.    WARN
            ${issue_list}=    Create List
        END
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=Mailgun should not be rejecting messages for this domain
                ...    actual=${issue['details']}
                ...    title=${issue['title']}
                ...    reproduce_hint=${result.cmd}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_steps']}
            END
        END
        RW.Core.Add Pre To Report    Rejected events (${DOMAIN}):\n${result.stdout}
    END

Verify SPF Record for Mailgun Sending Domains in Scope
    [Documentation]    Resolves TXT/SPF and checks Mailgun include expectations using API-ground truth when available.
    [Tags]    Mailgun    email    DNS    SPF    access:read-only    data:logs-config

    FOR    ${DOMAIN}    IN    @{DOMAIN_LIST}
        ${env_d}=    Copy Dictionary    ${env}
        Set To Dictionary    ${env_d}    MAILGUN_SENDING_DOMAIN    ${DOMAIN}
        ${result}=    RW.CLI.Run Bash File
        ...    bash_file=verify-mailgun-spf-dns.sh
        ...    env=${env_d}
        ...    secret__mailgun_api_key=${mailgun_api_key}
        ...    include_in_history=false
        ...    timeout_seconds=180
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=MAILGUN_SENDING_DOMAIN="${DOMAIN}" ./verify-mailgun-spf-dns.sh
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat mailgun_spf_issues.json
        ...    timeout_seconds=30
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        EXCEPT
            Log    Failed to parse JSON for SPF task, defaulting to empty list.    WARN
            ${issue_list}=    Create List
        END
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=SPF should authorize Mailgun for this sending domain
                ...    actual=${issue['details']}
                ...    title=${issue['title']}
                ...    reproduce_hint=${result.cmd}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_steps']}
            END
        END
        RW.Core.Add Pre To Report    SPF (${DOMAIN}):\n${result.stdout}
    END

Verify DKIM DNS Records for Mailgun Domains in Scope
    [Documentation]    Confirms DKIM TXT records in DNS match Mailgun-reported expectations for each selector.
    [Tags]    Mailgun    email    DNS    DKIM    access:read-only    data:logs-config

    FOR    ${DOMAIN}    IN    @{DOMAIN_LIST}
        ${env_d}=    Copy Dictionary    ${env}
        Set To Dictionary    ${env_d}    MAILGUN_SENDING_DOMAIN    ${DOMAIN}
        ${result}=    RW.CLI.Run Bash File
        ...    bash_file=verify-mailgun-dkim-dns.sh
        ...    env=${env_d}
        ...    secret__mailgun_api_key=${mailgun_api_key}
        ...    include_in_history=false
        ...    timeout_seconds=180
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=MAILGUN_SENDING_DOMAIN="${DOMAIN}" ./verify-mailgun-dkim-dns.sh
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat mailgun_dkim_issues.json
        ...    timeout_seconds=30
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        EXCEPT
            Log    Failed to parse JSON for DKIM task, defaulting to empty list.    WARN
            ${issue_list}=    Create List
        END
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=DKIM TXT records should match Mailgun-published values and be active
                ...    actual=${issue['details']}
                ...    title=${issue['title']}
                ...    reproduce_hint=${result.cmd}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_steps']}
            END
        END
        RW.Core.Add Pre To Report    DKIM (${DOMAIN}):\n${result.stdout}
    END

Verify DMARC Policy for Mailgun Sending Domains in Scope
    [Documentation]    Checks _dmarc TXT presence for the organizational domain used in From headers.
    [Tags]    Mailgun    email    DNS    DMARC    access:read-only    data:logs-config

    FOR    ${DOMAIN}    IN    @{DOMAIN_LIST}
        ${env_d}=    Copy Dictionary    ${env}
        Set To Dictionary    ${env_d}    MAILGUN_SENDING_DOMAIN    ${DOMAIN}
        ${result}=    RW.CLI.Run Bash File
        ...    bash_file=verify-mailgun-dmarc-dns.sh
        ...    env=${env_d}
        ...    secret__mailgun_api_key=${mailgun_api_key}
        ...    include_in_history=false
        ...    timeout_seconds=120
        ...    show_in_rwl_cheatsheet=false
        ...    cmd_override=MAILGUN_SENDING_DOMAIN="${DOMAIN}" ./verify-mailgun-dmarc-dns.sh
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat mailgun_dmarc_issues.json
        ...    timeout_seconds=30
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        EXCEPT
            Log    Failed to parse JSON for DMARC task, defaulting to empty list.    WARN
            ${issue_list}=    Create List
        END
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=A DMARC TXT record should be published for the sending domain org
                ...    actual=${issue['details']}
                ...    title=${issue['title']}
                ...    reproduce_hint=${result.cmd}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_steps']}
            END
        END
        RW.Core.Add Pre To Report    DMARC (${DOMAIN}):\n${result.stdout}
    END

Verify MX Records for Mailgun Domains When MX Verification Is Enabled
    [Documentation]    When MAILGUN_VERIFY_MX is true, validates published MX against Mailgun receiving hints for inbound routing.
    [Tags]    Mailgun    email    DNS    MX    access:read-only    data:logs-config

    FOR    ${DOMAIN}    IN    @{DOMAIN_LIST}
        ${env_d}=    Copy Dictionary    ${env}
        Set To Dictionary    ${env_d}    MAILGUN_SENDING_DOMAIN    ${DOMAIN}
        ${result}=    RW.CLI.Run Bash File
        ...    bash_file=verify-mailgun-mx-dns.sh
        ...    env=${env_d}
        ...    secret__mailgun_api_key=${mailgun_api_key}
        ...    include_in_history=false
        ...    timeout_seconds=120
        ...    show_in_rwl_cheatsheet=false
        ...    cmd_override=MAILGUN_SENDING_DOMAIN="${DOMAIN}" ./verify-mailgun-mx-dns.sh
        ${issues}=    RW.CLI.Run Cli
        ...    cmd=cat mailgun_mx_issues.json
        ...    timeout_seconds=30
        TRY
            ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
        EXCEPT
            Log    Failed to parse JSON for MX task, defaulting to empty list.    WARN
            ${issue_list}=    Create List
        END
        IF    len(@{issue_list}) > 0
            FOR    ${issue}    IN    @{issue_list}
                RW.Core.Add Issue
                ...    severity=${issue['severity']}
                ...    expected=MX records should match the intended inbound configuration when verification is enabled
                ...    actual=${issue['details']}
                ...    title=${issue['title']}
                ...    reproduce_hint=${result.cmd}
                ...    details=${issue['details']}
                ...    next_steps=${issue['next_steps']}
            END
        END
        RW.Core.Add Pre To Report    MX (${DOMAIN}):\n${result.stdout}
    END

*** Keywords ***
Suite Initialization
    TRY
        ${mailgun_api_key}=    RW.Core.Import Secret    mailgun_api_key
        ...    type=string
        ...    description=Mailgun private API key (HTTP Basic user=api, password=key)
        ...    pattern=\w*
        Set Suite Variable    ${mailgun_api_key}    ${mailgun_api_key}
    EXCEPT
        Log    mailgun_api_key secret not found; Mailgun API tasks will fail until configured.    WARN
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
    ${RESOURCES}=    RW.Core.Import User Variable    RESOURCES
    ...    type=string
    ...    description=Specific domain FQDN or All to list domains via the Mailgun API.
    ...    pattern=\w*
    ...    default=All
    ${MAILGUN_STATS_WINDOW_HOURS}=    RW.Core.Import User Variable    MAILGUN_STATS_WINDOW_HOURS
    ...    type=string
    ...    description=Rolling window in hours for Mailgun stats queries.
    ...    pattern=^\d+$
    ...    default=24
    ${MAILGUN_MIN_DELIVERY_SUCCESS_PCT}=    RW.Core.Import User Variable    MAILGUN_MIN_DELIVERY_SUCCESS_PCT
    ...    type=string
    ...    description=Minimum acceptable delivered divided by delivered plus failed percentage.
    ...    pattern=^[0-9.]+$
    ...    default=95
    ${MAILGUN_MAX_BOUNCE_RATE_PCT}=    RW.Core.Import User Variable    MAILGUN_MAX_BOUNCE_RATE_PCT
    ...    type=string
    ...    description=Maximum acceptable bounce rate percentage vs accepted volume.
    ...    pattern=^[0-9.]+$
    ...    default=5
    ${MAILGUN_MAX_COMPLAINT_RATE_PCT}=    RW.Core.Import User Variable    MAILGUN_MAX_COMPLAINT_RATE_PCT
    ...    type=string
    ...    description=Maximum acceptable complaint rate percentage vs accepted volume.
    ...    pattern=^[0-9.]+$
    ...    default=0.1
    ${MAILGUN_VERIFY_MX}=    RW.Core.Import User Variable    MAILGUN_VERIFY_MX
    ...    type=string
    ...    description=Set true to enforce MX checks for inbound routing.
    ...    pattern=^(true|false|True|False|1|0|yes|no)?$
    ...    default=false
    ${MAILGUN_VOLUME_DROP_THRESHOLD_PCT}=    RW.Core.Import User Variable    MAILGUN_VOLUME_DROP_THRESHOLD_PCT
    ...    type=string
    ...    description=Week-over-week volume decline percentage that triggers an alert (e.g. 80 means a drop of 80%+).
    ...    pattern=^[0-9.]+$
    ...    default=80
    ${MAILGUN_DELIVERED_SAMPLE_SIZE}=    RW.Core.Import User Variable    MAILGUN_DELIVERED_SAMPLE_SIZE
    ...    type=string
    ...    description=Number of recent delivered messages to sample in the report.
    ...    pattern=^\d+$
    ...    default=10

    ${env}=    Create Dictionary
    ...    MAILGUN_API_REGION=${MAILGUN_API_REGION}
    ...    MAILGUN_STATS_WINDOW_HOURS=${MAILGUN_STATS_WINDOW_HOURS}
    ...    MAILGUN_MIN_DELIVERY_SUCCESS_PCT=${MAILGUN_MIN_DELIVERY_SUCCESS_PCT}
    ...    MAILGUN_MAX_BOUNCE_RATE_PCT=${MAILGUN_MAX_BOUNCE_RATE_PCT}
    ...    MAILGUN_MAX_COMPLAINT_RATE_PCT=${MAILGUN_MAX_COMPLAINT_RATE_PCT}
    ...    MAILGUN_VERIFY_MX=${MAILGUN_VERIFY_MX}
    ...    MAILGUN_VOLUME_DROP_THRESHOLD_PCT=${MAILGUN_VOLUME_DROP_THRESHOLD_PCT}
    ...    MAILGUN_DELIVERED_SAMPLE_SIZE=${MAILGUN_DELIVERED_SAMPLE_SIZE}
    ...    RESOURCES=${RESOURCES}

    IF    '${RESOURCES}' == 'All'
        ${disco}=    RW.CLI.Run Bash File
        ...    bash_file=discover-mailgun-domains.sh
        ...    env=${env}
        ...    secret__mailgun_api_key=${mailgun_api_key}
        ...    include_in_history=false
        ...    timeout_seconds=120
        ...    show_in_rwl_cheatsheet=true
        ...    cmd_override=./discover-mailgun-domains.sh
        TRY
            ${DOMAIN_LIST}=    Evaluate    json.loads(r'''${disco.stdout}''')    json
        EXCEPT
            Log    Failed to parse discovery JSON; defaulting to empty list.    WARN
            ${DOMAIN_LIST}=    Create List
        END
        ${dl}=    Get Length    ${DOMAIN_LIST}
        IF    ${dl} == 0 and '${MAILGUN_SENDING_DOMAIN}' != ''
            ${DOMAIN_LIST}=    Create List    ${MAILGUN_SENDING_DOMAIN}
        END
    ELSE
        ${DOMAIN_LIST}=    Create List    ${RESOURCES}
    END

    Set Suite Variable    ${MAILGUN_SENDING_DOMAIN}    ${MAILGUN_SENDING_DOMAIN}
    Set Suite Variable    ${MAILGUN_API_REGION}    ${MAILGUN_API_REGION}
    Set Suite Variable    ${RESOURCES}    ${RESOURCES}
    Set Suite Variable    ${MAILGUN_STATS_WINDOW_HOURS}    ${MAILGUN_STATS_WINDOW_HOURS}
    Set Suite Variable    ${MAILGUN_MIN_DELIVERY_SUCCESS_PCT}    ${MAILGUN_MIN_DELIVERY_SUCCESS_PCT}
    Set Suite Variable    ${MAILGUN_MAX_BOUNCE_RATE_PCT}    ${MAILGUN_MAX_BOUNCE_RATE_PCT}
    Set Suite Variable    ${MAILGUN_MAX_COMPLAINT_RATE_PCT}    ${MAILGUN_MAX_COMPLAINT_RATE_PCT}
    Set Suite Variable    ${MAILGUN_VERIFY_MX}    ${MAILGUN_VERIFY_MX}
    Set Suite Variable    ${MAILGUN_VOLUME_DROP_THRESHOLD_PCT}    ${MAILGUN_VOLUME_DROP_THRESHOLD_PCT}
    Set Suite Variable    ${MAILGUN_DELIVERED_SAMPLE_SIZE}    ${MAILGUN_DELIVERED_SAMPLE_SIZE}
    Set Suite Variable    ${DOMAIN_LIST}    ${DOMAIN_LIST}
    Set Suite Variable    ${env}    ${env}
