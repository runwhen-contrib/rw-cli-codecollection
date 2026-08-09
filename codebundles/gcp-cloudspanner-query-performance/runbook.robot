*** Settings ***
Documentation       Monitors GCP Cloud Spanner query-level performance via the SPANNER_SYS introspection tables, surfacing high-latency queries, lock contention, transaction aborts, long-running queries, and CPU-heavy hot spots.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Cloud Spanner Query Performance
Metadata            Supports    GCP,Spanner
Force Tags          GCP    Spanner    Query    Performance

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Check Cloud Spanner High-Latency Queries for `${GCP_PROJECT_ID}`
    [Documentation]    Queries SPANNER_SYS.QUERY_STATS_TOP_* ordered by average latency and flags query shapes whose mean latency exceeds the threshold, reporting the query text and execution count.
    [Tags]    gcp    spanner    query    latency    data:metrics    access:read-only
    ${latency_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_high_latency_queries.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_high_latency_queries.sh
    ${latency_issues}=    RW.CLI.Run Cli
    ...    cmd=cat high_latency_queries_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${latency_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for high-latency queries, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${latency_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud Spanner High-Latency Query Analysis:\n${latency_result.stdout}

Check Cloud Spanner Lock Contention for `${GCP_PROJECT_ID}`
    [Documentation]    Queries SPANNER_SYS.LOCK_STATS_TOP_* and flags contended row-key ranges with lock wait time above the threshold, reporting the sample lock-requesting columns.
    [Tags]    gcp    spanner    query    locks    contention    data:metrics    access:read-only
    ${lock_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_lock_contention.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_lock_contention.sh
    ${lock_issues}=    RW.CLI.Run Cli
    ...    cmd=cat lock_contention_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${lock_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for lock contention, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${lock_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud Spanner Lock Contention Analysis:\n${lock_result.stdout}

Check Cloud Spanner Transaction Abort Rate for `${GCP_PROJECT_ID}`
    [Documentation]    Queries SPANNER_SYS.TXN_STATS_TOP_* and flags transaction shapes whose abort or commit-retry rate exceeds the threshold, which indicates contention or hotspotting.
    [Tags]    gcp    spanner    query    transactions    aborts    data:metrics    access:read-only
    ${txn_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_transaction_aborts.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_transaction_aborts.sh
    ${txn_issues}=    RW.CLI.Run Cli
    ...    cmd=cat transaction_aborts_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${txn_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for transaction aborts, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${txn_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud Spanner Transaction Abort Rate Analysis:\n${txn_result.stdout}

Check Cloud Spanner Long-Running Queries for `${GCP_PROJECT_ID}`
    [Documentation]    Queries SPANNER_SYS.OLDEST_ACTIVE_QUERIES and flags queries currently running longer than the threshold, reporting elapsed time and query text.
    [Tags]    gcp    spanner    query    long-running    data:metrics    access:read-only
    ${long_running_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_long_running_queries.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_long_running_queries.sh
    ${long_running_issues}=    RW.CLI.Run Cli
    ...    cmd=cat long_running_queries_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${long_running_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for long-running queries, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${long_running_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud Spanner Long-Running Query Analysis:\n${long_running_result.stdout}

Check Cloud Spanner CPU-Heavy Queries for `${GCP_PROJECT_ID}`
    [Documentation]    Queries SPANNER_SYS.QUERY_STATS_TOP_* ordered by CPU time and flags queries consuming a disproportionate share of instance CPU (hot spots).
    [Tags]    gcp    spanner    query    cpu    data:metrics    access:read-only
    ${cpu_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_cpu_heavy_queries.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_cpu_heavy_queries.sh
    ${cpu_issues}=    RW.CLI.Run Cli
    ...    cmd=cat cpu_heavy_queries_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${cpu_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for CPU-heavy queries, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${cpu_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud Spanner CPU-Heavy Query Analysis:\n${cpu_result.stdout}


*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON key used to authenticate with GCP APIs. Requires Spanner Database Reader (spanner.databases.select) to read SPANNER_SYS via execute-sql.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID"}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=GCP Project ID containing the Cloud Spanner instances.
    ...    pattern=\w*
    ...    example=my-gcp-project
    ${QUERY_LATENCY_THRESHOLD_MS}=    RW.Core.Import User Variable    QUERY_LATENCY_THRESHOLD_MS
    ...    type=string
    ...    description=Mean query latency (ms) above which a query is flagged.
    ...    pattern=\w*
    ...    default=100
    ${LOCK_WAIT_THRESHOLD_MS}=    RW.Core.Import User Variable    LOCK_WAIT_THRESHOLD_MS
    ...    type=string
    ...    description=Total lock wait time (ms) for a row range above which it is flagged.
    ...    pattern=\w*
    ...    default=1000
    ${ABORT_RATE_THRESHOLD_PERCENT}=    RW.Core.Import User Variable    ABORT_RATE_THRESHOLD_PERCENT
    ...    type=string
    ...    description=Transaction abort/commit-retry percent above which a transaction shape is flagged.
    ...    pattern=\w*
    ...    default=5
    ${LONG_RUNNING_QUERY_THRESHOLD_SECONDS}=    RW.Core.Import User Variable    LONG_RUNNING_QUERY_THRESHOLD_SECONDS
    ...    type=string
    ...    description=Elapsed time (s) above which an active query is flagged as long-running.
    ...    pattern=\w*
    ...    default=60
    ${STATS_WINDOW}=    RW.Core.Import User Variable    STATS_WINDOW
    ...    type=string
    ...    description=SPANNER_SYS stats window granularity used to build table names (QUERY_STATS_TOP_<window>, etc).
    ...    enum=[MINUTE,10MINUTE,HOUR]
    ...    default=HOUR
    ${CPU_TIME_SHARE_THRESHOLD_PERCENT}=    RW.Core.Import User Variable    CPU_TIME_SHARE_THRESHOLD_PERCENT
    ...    type=string
    ...    description=Share (percent) of the top query shapes' combined CPU time a single query shape can consume before it is flagged as a CPU hot spot.
    ...    pattern=\w*
    ...    default=25
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${QUERY_LATENCY_THRESHOLD_MS}    ${QUERY_LATENCY_THRESHOLD_MS}
    Set Suite Variable    ${LOCK_WAIT_THRESHOLD_MS}    ${LOCK_WAIT_THRESHOLD_MS}
    Set Suite Variable    ${ABORT_RATE_THRESHOLD_PERCENT}    ${ABORT_RATE_THRESHOLD_PERCENT}
    Set Suite Variable    ${LONG_RUNNING_QUERY_THRESHOLD_SECONDS}    ${LONG_RUNNING_QUERY_THRESHOLD_SECONDS}
    Set Suite Variable    ${STATS_WINDOW}    ${STATS_WINDOW}
    Set Suite Variable    ${CPU_TIME_SHARE_THRESHOLD_PERCENT}    ${CPU_TIME_SHARE_THRESHOLD_PERCENT}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","CLOUDSDK_BILLING_QUOTA_PROJECT":"${GCP_PROJECT_ID}","QUERY_LATENCY_THRESHOLD_MS":"${QUERY_LATENCY_THRESHOLD_MS}","LOCK_WAIT_THRESHOLD_MS":"${LOCK_WAIT_THRESHOLD_MS}","ABORT_RATE_THRESHOLD_PERCENT":"${ABORT_RATE_THRESHOLD_PERCENT}","LONG_RUNNING_QUERY_THRESHOLD_SECONDS":"${LONG_RUNNING_QUERY_THRESHOLD_SECONDS}","STATS_WINDOW":"${STATS_WINDOW}","CPU_TIME_SHARE_THRESHOLD_PERCENT":"${CPU_TIME_SHARE_THRESHOLD_PERCENT}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
