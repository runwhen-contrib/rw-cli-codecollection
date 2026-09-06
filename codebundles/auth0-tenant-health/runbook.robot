*** Settings ***
Documentation       Monitors the overall health of an upstream Auth0 tenant by verifying the Auth0 platform is reachable, custom login/authentication domains are functioning, and no actionable error, login-failure, or rate-limit signals are present in the tenant log stream.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Auth0 Tenant Service Health
Metadata            Supports    Auth0    tenant    health    monitoring    SRE

Force Tags          Auth0    tenant    health    monitoring    SRE

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Check Auth0 Tenant Service Availability for Tenant `${AUTH0_TENANT}`
    [Documentation]    Verifies the tenant is reachable by resolving its domain and querying well-known discovery endpoints plus the Management API. Raises an issue if the service is unreachable or returns 5xx.
    [Tags]    Auth0    tenant    access:read-only    data:service-status
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=tenant_availability.sh
    ...    env=${env}
    ...    secret__AUTH0_MGMT_CREDENTIALS=${AUTH0_MGMT_CREDENTIALS}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./tenant_availability.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat tenant_availability_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for tenant availability, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=The Auth0 tenant service should be reachable and return 200-level responses from discovery and Management API endpoints
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Auth0 Tenant Service Availability Check Results:\n\n${result.stdout}
    RW.Core.Add Pre To Report    Tenant availability issues JSON:\n\n${issues.stdout}

Check Custom Domain Health for Tenant `${AUTH0_TENANT}`
    [Documentation]    Validates each configured custom domain for DNS resolution, TLS certificate validity/expiry, and verified status via the Custom Domains API. Raises issues for failed verification, expired certificates, or broken redirects.
    [Tags]    Auth0    tenant    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=custom_domain_health.sh
    ...    env=${env}
    ...    secret__AUTH0_MGMT_CREDENTIALS=${AUTH0_MGMT_CREDENTIALS}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./custom_domain_health.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat custom_domain_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for custom domain health, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=All custom domains should be verified, resolve via DNS, and have valid, non-expiring TLS certificates
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Custom Domain Health Check Results:\n\n${result.stdout}
    RW.Core.Add Pre To Report    Custom domain issues JSON:\n\n${issues.stdout}

Analyze Tenant Error Logs for Tenant `${AUTH0_TENANT}`
    [Documentation]    Pulls recent log events from the Logs API, buckets them by type, and flags error, warn, and anomaly event classes. Emits issues for spikes or repeated error types within the lookback window.
    [Tags]    Auth0    tenant    access:read-only    data:logs
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_error_logs.sh
    ...    env=${env}
    ...    secret__AUTH0_MGMT_CREDENTIALS=${AUTH0_MGMT_CREDENTIALS}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./analyze_error_logs.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat error_logs_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for error log analysis, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=No repeated error, warn, or anomaly event classes should spike within the lookback window
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Tenant Error Log Analysis Results:\n\n${result.stdout}
    RW.Core.Add Pre To Report    Error log issues JSON:\n\n${issues.stdout}

Check Login Failures and Anomalous Activity for Tenant `${AUTH0_TENANT}`
    [Documentation]    Detects elevated login-failure and fraud/hack attempts from the log stream such as blocked users, brute-force patterns, and passwordless failures, reporting per-connection anomalies against a configurable threshold.
    [Tags]    Auth0    tenant    access:read-only    data:logs
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=login_failure_analysis.sh
    ...    env=${env}
    ...    secret__AUTH0_MGMT_CREDENTIALS=${AUTH0_MGMT_CREDENTIALS}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./login_failure_analysis.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat login_failure_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for login failure analysis, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Login failure and anomalous-activity counts should stay below the configured threshold with no blocked/flagged users
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Login Failure and Anomaly Analysis Results:\n\n${result.stdout}
    RW.Core.Add Pre To Report    Login failure issues JSON:\n\n${issues.stdout}

Check Rate Limit and Throttling Signals for Tenant `${AUTH0_TENANT}`
    [Documentation]    Monitors the tenant for rate-limit events and 429 responses across the Management API and authentication traffic. Raises issues when rate-limit utilization approaches checkpoint limits or sustained throttling is observed.
    [Tags]    Auth0    tenant    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=rate_limit_health.sh
    ...    env=${env}
    ...    secret__AUTH0_MGMT_CREDENTIALS=${AUTH0_MGMT_CREDENTIALS}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./rate_limit_health.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat rate_limit_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for rate limit health, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Management API rate-limit utilization should stay below the threshold and no sustained throttling/429 events should occur
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Rate Limit and Throttling Check Results:\n\n${result.stdout}
    RW.Core.Add Pre To Report    Rate limit issues JSON:\n\n${issues.stdout}

Verify Log Stream Delivery Health for Tenant `${AUTH0_TENANT}`
    [Documentation]    Checks that configured Log Streams are enabled and delivering with no backlog or failure states so log-based monitoring and retention accurately reflect tenant activity.
    [Tags]    Auth0    tenant    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=log_stream_health.sh
    ...    env=${env}
    ...    secret__AUTH0_MGMT_CREDENTIALS=${AUTH0_MGMT_CREDENTIALS}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./log_stream_health.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat log_stream_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for log stream health, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=All configured log streams should be active and delivering without backlog or failure states
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Log Stream Delivery Health Check Results:\n\n${result.stdout}
    RW.Core.Add Pre To Report    Log stream issues JSON:\n\n${issues.stdout}


*** Keywords ***
Suite Initialization
    TRY
        ${AUTH0_MGMT_CREDENTIALS}=    RW.Core.Import Secret    AUTH0_MGMT_CREDENTIALS
        ...    type=string
        ...    description=Auth0 Management API client credentials. JSON with client_id and client_secret, or a raw MAPI bearer token.
        ...    pattern=.*
        Set Suite Variable    ${AUTH0_MGMT_CREDENTIALS}    ${AUTH0_MGMT_CREDENTIALS}
    EXCEPT
        Log    AUTH0_MGMT_CREDENTIALS secret not provided; Auth0 API tasks will fail until configured.    WARN
        Set Suite Variable    ${AUTH0_MGMT_CREDENTIALS}    ${EMPTY}
    END
    ${AUTH0_TENANT}=    RW.Core.Import User Variable    AUTH0_TENANT
    ...    type=string
    ...    description=Auth0 tenant name (e.g. mytenant; the full domain mytenant.auth0.com is derived from it).
    ...    pattern=[a-zA-Z0-9-._]+
    ${LOG_LOOKBACK_HOURS}=    RW.Core.Import User Variable    LOG_LOOKBACK_HOURS
    ...    type=string
    ...    description=How far back to analyze tenant logs (hours).
    ...    pattern=^\d+$
    ...    default=24
    ${LOGIN_FAILURE_THRESHOLD}=    RW.Core.Import User Variable    LOGIN_FAILURE_THRESHOLD
    ...    type=string
    ...    description=Number of login failures within the lookback window to flag an anomaly.
    ...    pattern=^\d+$
    ...    default=50
    ${RATE_LIMIT_THRESHOLD_PCT}=    RW.Core.Import User Variable    RATE_LIMIT_THRESHOLD_PCT
    ...    type=string
    ...    description=Rate limit utilization % above which a warning issue is raised.
    ...    pattern=^\d+$
    ...    default=80
    ${CERT_EXPIRY_WARN_DAYS}=    RW.Core.Import User Variable    CERT_EXPIRY_WARN_DAYS
    ...    type=string
    ...    description=Days before custom-domain certificate expiry to raise a warning.
    ...    pattern=^\d+$
    ...    default=30
    Set Suite Variable    ${AUTH0_TENANT}    ${AUTH0_TENANT}
    Set Suite Variable    ${LOG_LOOKBACK_HOURS}    ${LOG_LOOKBACK_HOURS}
    Set Suite Variable    ${LOGIN_FAILURE_THRESHOLD}    ${LOGIN_FAILURE_THRESHOLD}
    Set Suite Variable    ${RATE_LIMIT_THRESHOLD_PCT}    ${RATE_LIMIT_THRESHOLD_PCT}
    Set Suite Variable    ${CERT_EXPIRY_WARN_DAYS}    ${CERT_EXPIRY_WARN_DAYS}

    ${env}=    Create Dictionary
    ...    AUTH0_TENANT=${AUTH0_TENANT}
    ...    LOG_LOOKBACK_HOURS=${LOG_LOOKBACK_HOURS}
    ...    LOGIN_FAILURE_THRESHOLD=${LOGIN_FAILURE_THRESHOLD}
    ...    RATE_LIMIT_THRESHOLD_PCT=${RATE_LIMIT_THRESHOLD_PCT}
    ...    CERT_EXPIRY_WARN_DAYS=${CERT_EXPIRY_WARN_DAYS}
    Set Suite Variable    ${env}    ${env}