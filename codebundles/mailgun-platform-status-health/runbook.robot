*** Settings ***
Documentation       Detects Mailgun-wide service disruptions and loss of regional API reachability using public status sources and unauthenticated HTTP probes before authenticated domain checks.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Mailgun Platform Status & Reachability
Metadata            Supports    Mailgun network_service platform-status
Force Tags          Mailgun    network_service    platform-status

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check Mailgun Status Page for Published Incidents (region focus `${MAILGUN_STATUS_REGION_FOCUS}`)
    [Documentation]    Fetches Mailgun Statuspage JSON for overall health, degraded components, unresolved incidents, and active maintenance windows that can explain delivery or API issues without using API keys.
    [Tags]    mailgun    status    platform    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-mailgun-status-incidents.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=MAILGUN_STATUS_LOOKBACK_HOURS="${MAILGUN_STATUS_LOOKBACK_HOURS}" ./check-mailgun-status-incidents.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat status_incidents_output.json
    ...    env=${env}

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Mailgun status snapshot (stdout):
    RW.Core.Add Pre To Report    ${result.stdout}

Check Mailgun Public Incident Feed for Recent Critical Events (lookback `${MAILGUN_STATUS_LOOKBACK_HOURS}`h)
    [Documentation]    Reads the Statuspage incidents JSON for major or critical incidents resolved inside the lookback window to surface recent platform risk even when the banner is green.
    [Tags]    mailgun    incidents    feed    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-mailgun-incident-feed.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=MAILGUN_STATUS_LOOKBACK_HOURS="${MAILGUN_STATUS_LOOKBACK_HOURS}" ./check-mailgun-incident-feed.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat incident_feed_output.json
    ...    env=${env}

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Mailgun incident feed results:
    RW.Core.Add Pre To Report    ${result.stdout}

Verify Mailgun US API Endpoint Reachability (focus `${MAILGUN_STATUS_REGION_FOCUS}`)
    [Documentation]    Performs a TLS and HTTP probe to api.mailgun.net expecting HTTP 401 without credentials, confirming US regional routing and availability.
    [Tags]    mailgun    api    us    reachability    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-mailgun-api-us-reachability.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=MAILGUN_STATUS_REGION_FOCUS="${MAILGUN_STATUS_REGION_FOCUS}" ./check-mailgun-api-us-reachability.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat api_us_reachability_output.json
    ...    env=${env}

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Mailgun US API reachability:
    RW.Core.Add Pre To Report    ${result.stdout}

Verify Mailgun EU API Endpoint Reachability (focus `${MAILGUN_STATUS_REGION_FOCUS}`)
    [Documentation]    Same unauthenticated probe for api.eu.mailgun.net when EU routing matters to the workspace.
    [Tags]    mailgun    api    eu    reachability    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-mailgun-api-eu-reachability.sh
    ...    env=${env}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=MAILGUN_STATUS_REGION_FOCUS="${MAILGUN_STATUS_REGION_FOCUS}" ./check-mailgun-api-eu-reachability.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat api_eu_reachability_output.json
    ...    env=${env}

    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END

    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END

    RW.Core.Add Pre To Report    Mailgun EU API reachability:
    RW.Core.Add Pre To Report    ${result.stdout}


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
    ...    description=Hours of incident history to treat as recent for feed correlation.
    ...    pattern=^\d+$
    ...    default=24

    Set Suite Variable    ${MAILGUN_STATUS_REGION_FOCUS}    ${MAILGUN_STATUS_REGION_FOCUS}
    Set Suite Variable    ${MAILGUN_STATUS_LOOKBACK_HOURS}    ${MAILGUN_STATUS_LOOKBACK_HOURS}

    ${env_dict}=    Create Dictionary
    ...    MAILGUN_STATUS_REGION_FOCUS=${MAILGUN_STATUS_REGION_FOCUS}
    ...    MAILGUN_STATUS_LOOKBACK_HOURS=${MAILGUN_STATUS_LOOKBACK_HOURS}
    Set Suite Variable    ${env}    ${env_dict}
