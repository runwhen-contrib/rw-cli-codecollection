*** Settings ***
Documentation       Measures Cloud Spanner query-level performance by scoring high-latency queries, lock contention, transaction abort rate, long-running queries, and CPU-heavy query hot spots read from SPANNER_SYS. Produces a value between 0 (completely failing) and 1 (fully passing).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Cloud Spanner Query Performance
Metadata            Supports    GCP,Spanner
Suite Setup         Suite Initialization
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections


*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON key used to authenticate with GCP APIs. Requires Spanner Database Reader (spanner.databases.select) to read SPANNER_SYS via execute-sql.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID"}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID to scope the API to.
    ...    pattern=\w*
    ...    example=myproject-id
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
    ...    {"PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","QUERY_LATENCY_THRESHOLD_MS":"${QUERY_LATENCY_THRESHOLD_MS}","LOCK_WAIT_THRESHOLD_MS":"${LOCK_WAIT_THRESHOLD_MS}","ABORT_RATE_THRESHOLD_PERCENT":"${ABORT_RATE_THRESHOLD_PERCENT}","LONG_RUNNING_QUERY_THRESHOLD_SECONDS":"${LONG_RUNNING_QUERY_THRESHOLD_SECONDS}","STATS_WINDOW":"${STATS_WINDOW}","CPU_TIME_SHARE_THRESHOLD_PERCENT":"${CPU_TIME_SHARE_THRESHOLD_PERCENT}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}


*** Tasks ***
Score Cloud Spanner High-Latency Queries for `${GCP_PROJECT_ID}`
    [Documentation]    Scores query latency against SPANNER_SYS.QUERY_STATS_TOP_*. Returns 1 if no query shape exceeds the latency threshold.
    [Tags]    gcp    spanner    query    latency    data:metrics    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_high_latency_queries.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat high_latency_queries_issues.json | jq length
    ...    env=${env}
    ${latency_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${latency_score}
    RW.Core.Push Metric    ${latency_score}    sub_name=high_latency_queries

Score Cloud Spanner Lock Contention for `${GCP_PROJECT_ID}`
    [Documentation]    Scores lock contention against SPANNER_SYS.LOCK_STATS_TOP_*. Returns 1 if no row-key range exceeds the lock-wait threshold.
    [Tags]    gcp    spanner    query    locks    data:metrics    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_lock_contention.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat lock_contention_issues.json | jq length
    ...    env=${env}
    ${lock_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${lock_score}
    RW.Core.Push Metric    ${lock_score}    sub_name=lock_contention

Score Cloud Spanner Transaction Abort Rate for `${GCP_PROJECT_ID}`
    [Documentation]    Scores transaction abort rate against SPANNER_SYS.TXN_STATS_TOP_*. Returns 1 if no transaction shape exceeds the abort-rate threshold.
    [Tags]    gcp    spanner    query    transactions    data:metrics    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_transaction_aborts.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat transaction_aborts_issues.json | jq length
    ...    env=${env}
    ${txn_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${txn_score}
    RW.Core.Push Metric    ${txn_score}    sub_name=transaction_aborts

Score Cloud Spanner Long-Running Queries for `${GCP_PROJECT_ID}`
    [Documentation]    Scores active query age against SPANNER_SYS.OLDEST_ACTIVE_QUERIES. Returns 1 if no active query exceeds the long-running threshold.
    [Tags]    gcp    spanner    query    long-running    data:metrics    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_long_running_queries.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat long_running_queries_issues.json | jq length
    ...    env=${env}
    ${long_running_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${long_running_score}
    RW.Core.Push Metric    ${long_running_score}    sub_name=long_running_queries

Score Cloud Spanner CPU-Heavy Queries for `${GCP_PROJECT_ID}`
    [Documentation]    Scores CPU-time concentration against SPANNER_SYS.QUERY_STATS_TOP_*. Returns 1 if no query shape is a disproportionate CPU hot spot.
    [Tags]    gcp    spanner    query    cpu    data:metrics    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_cpu_heavy_queries.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat cpu_heavy_queries_issues.json | jq length
    ...    env=${env}
    ${cpu_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${cpu_score}
    RW.Core.Push Metric    ${cpu_score}    sub_name=cpu_heavy_queries

Generate Aggregate Cloud Spanner Query Performance Score for `${GCP_PROJECT_ID}`
    [Documentation]    Averages all sub-scores into a final 0-1 query-performance score for the project.
    [Tags]    gcp    spanner    query    performance    data:metrics    access:read-only
    ${query_performance_score}=    Evaluate    (${latency_score} + ${lock_score} + ${txn_score} + ${long_running_score} + ${cpu_score}) / 5
    ${health_score}=    Convert to Number    ${query_performance_score}    2
    RW.Core.Add to Report    Cloud Spanner Query Performance Score: ${health_score}
    RW.Core.Push Metric    ${health_score}
