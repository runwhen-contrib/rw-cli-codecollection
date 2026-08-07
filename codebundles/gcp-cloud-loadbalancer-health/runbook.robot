*** Settings ***
Documentation       Identify health and performance problems with GCP Cloud Load Balancers (SSL, backends, error rates, and latency)
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Cloud Load Balancer Health
Metadata            Supports    GCP,Cloud Load Balancing,Load Balancer
Force Tags          GCP    Cloud Load Balancing    Load Balancer

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization

*** Tasks ***
Discover GCP Cloud Load Balancers and Configurations in `${GCP_PROJECT_ID}`
    [Documentation]    Lists all forwarding rules in the project, categorizes each by load balancer type (HTTP/S, SSL proxy, TCP proxy, Network), and dumps configuration including IP address, ports, target proxy, and backend service.
    [Tags]    gcloud    loadbalancer    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=discover_loadbalancers.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./discover_loadbalancers.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat lb_discovery_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for LB discovery, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    GCP Load Balancer Discovery:\n${result.stdout}

Check SSL Certificate Expiry for HTTPS/SSL Load Balancers in `${GCP_PROJECT_ID}`
    [Documentation]    For all HTTPS and SSL proxy load balancers, inspects the mapped SSL certificates and flags any that will expire within the configurable SSL_WARNING_DAYS threshold, reporting days remaining per certificate.
    [Tags]    gcloud    loadbalancer    ssl    gcp    ${GCP_PROJECT_ID}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_ssl_certificates.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_ssl_certificates.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat ssl_certificate_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for SSL certificates, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    SSL Certificate Expiry Analysis:\n${result.stdout}

Check Load Balancer Backend Health in `${GCP_PROJECT_ID}`
    [Documentation]    For each backend service used by the project's load balancers, checks backend health status and flags unhealthy backends, draining instances, and backends with degraded capacity.
    [Tags]    gcloud    loadbalancer    backend    gcp    ${GCP_PROJECT_ID}    access:read-only    data:state
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_backend_health.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_backend_health.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat backend_health_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for backend health, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Load Balancer Backend Health:\n${result.stdout}

Analyze Load Balancer Error Rates via Cloud Monitoring in `${GCP_PROJECT_ID}`
    [Documentation]    Queries Cloud Monitoring metrics for HTTP/S load balancer 5xx error ratios and non-HTTP LB error/health-check failure rates over the lookback period, flagging load balancers whose error rate exceeds the ERROR_RATE_THRESHOLD.
    [Tags]    gcloud    loadbalancer    monitoring    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_error_rates.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_error_rates.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat error_rate_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for error rates, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Load Balancer Error Rate Analysis:\n${result.stdout}

Analyze Load Balancer Latency Performance in `${GCP_PROJECT_ID}`
    [Documentation]    Queries Cloud Monitoring metrics for request latency (P50, P95, P99) on HTTP/S load balancers and health-check latency on non-HTTP LBs, flagging load balancers whose latency exceeds the LATENCY_THRESHOLD_MS.
    [Tags]    gcloud    loadbalancer    monitoring    gcp    ${GCP_PROJECT_ID}    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_latency.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_latency.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat latency_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for latency, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Load Balancer Latency Analysis:\n${result.stdout}

Generate Load Balancer Health Summary for `${GCP_PROJECT_ID}`
    [Documentation]    Aggregates findings from all previous checks into a consolidated health summary table showing each load balancer, its type, SSL status, backend status, error rate, latency, and an overall health verdict.
    [Tags]    gcloud    loadbalancer    gcp    ${GCP_PROJECT_ID}    access:read-only    data:state
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=generate_lb_summary.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./generate_lb_summary.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat lb_summary_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for LB summary, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Load Balancer Health Summary:\n${result.stdout}

*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account json used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID that hosts the load balancers to check.
    ...    pattern=\w*
    ...    example=myproject-ID
    ${SSL_WARNING_DAYS}=    RW.Core.Import User Variable    SSL_WARNING_DAYS
    ...    type=string
    ...    description=Number of days before SSL certificate expiry to raise a warning (severity 2).
    ...    pattern=^\d+$
    ...    default=30
    ${ERROR_RATE_THRESHOLD}=    RW.Core.Import User Variable    ERROR_RATE_THRESHOLD
    ...    type=string
    ...    description=Maximum acceptable 5xx error ratio (0.01 = 1%) before a load balancer is flagged.
    ...    pattern=^\d*\.?\d+$
    ...    default=0.01
    ${LATENCY_THRESHOLD_MS}=    RW.Core.Import User Variable    LATENCY_THRESHOLD_MS
    ...    type=string
    ...    description=Maximum acceptable P95 latency in milliseconds before a load balancer is flagged.
    ...    pattern=^\d+$
    ...    default=5000
    ${METRIC_LOOKBACK_PERIOD}=    RW.Core.Import User Variable    METRIC_LOOKBACK_PERIOD
    ...    type=string
    ...    description=Cloud Monitoring lookback period for metric queries (seconds, e.g. 3600s).
    ...    pattern=^\d+s$
    ...    default=3600s
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable    ${SSL_WARNING_DAYS}    ${SSL_WARNING_DAYS}
    Set Suite Variable    ${ERROR_RATE_THRESHOLD}    ${ERROR_RATE_THRESHOLD}
    Set Suite Variable    ${LATENCY_THRESHOLD_MS}    ${LATENCY_THRESHOLD_MS}
    Set Suite Variable    ${METRIC_LOOKBACK_PERIOD}    ${METRIC_LOOKBACK_PERIOD}
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","SSL_WARNING_DAYS":"${SSL_WARNING_DAYS}","ERROR_RATE_THRESHOLD":"${ERROR_RATE_THRESHOLD}","LATENCY_THRESHOLD_MS":"${LATENCY_THRESHOLD_MS}","METRIC_LOOKBACK_PERIOD":"${METRIC_LOOKBACK_PERIOD}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
