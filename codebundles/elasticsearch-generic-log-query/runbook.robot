*** Settings ***
Documentation       Runs configurable Elasticsearch log searches with the cluster base URL separated from the JSON query body so the same query can be reused across environments.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Elasticsearch Generic Log Search
Metadata            Supports    Elasticsearch    logs    HTTP    search

Force Tags          Elasticsearch    logs    search    HTTP

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization

*** Tasks ***
Check Elasticsearch Endpoint Reachability for `${ELASTICSEARCH_BASE_URL}`
    [Documentation]    Verifies HTTP(S) reachability and optional authentication to the configured Elasticsearch base URL before running searches.
    [Tags]    Elasticsearch    logs    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-elasticsearch-endpoint.sh
    ...    env=${env}
    ...    secret__elasticsearch_credentials=${elasticsearch_credentials}
    ...    include_in_history=false
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-elasticsearch-endpoint.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat endpoint_check_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for endpoint check task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Elasticsearch HTTP API should be reachable with a 2xx response from the base URL
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Endpoint check:\n${result.stdout}

Run Generic Log Search and Summarize Results for `${ELASTICSEARCH_INDEX_PATTERN}`
    [Documentation]    POSTs ELASTICSEARCH_QUERY_BODY to the Search API for the configured index pattern and records hit counts plus a bounded sample for the report.
    [Tags]    Elasticsearch    logs    access:read-only    data:logs

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=run-generic-log-search.sh
    ...    env=${env}
    ...    secret__elasticsearch_credentials=${elasticsearch_credentials}
    ...    include_in_history=false
    ...    timeout_seconds=180
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./run-generic-log-search.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat search_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for search task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Search request should return HTTP 2xx with valid JSON for the configured index and query
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Search summary:\n${result.stdout}

Evaluate Search Result Thresholds for `${ELASTICSEARCH_INDEX_PATTERN}`
    [Documentation]    Optionally compares total hit counts from the last search against configured min and max thresholds and raises issues when breached.
    [Tags]    Elasticsearch    logs    access:read-only    data:logs

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=evaluate-search-thresholds.sh
    ...    env=${env}
    ...    include_in_history=false
    ...    timeout_seconds=120
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./evaluate-search-thresholds.sh

    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat threshold_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for threshold task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Hit count should remain within optional SEARCH_THRESHOLD_MIN_HITS and SEARCH_THRESHOLD_MAX_HITS when those are set
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Threshold evaluation:\n${result.stdout}

*** Keywords ***
Suite Initialization
    TRY
        ${elasticsearch_credentials}=    RW.Core.Import Secret    elasticsearch_credentials
        ...    type=string
        ...    description=Optional JSON with ELASTICSEARCH_USERNAME, ELASTICSEARCH_PASSWORD, and/or ELASTICSEARCH_API_KEY
        ...    pattern=\w*
        Set Suite Variable    ${elasticsearch_credentials}    ${elasticsearch_credentials}
    EXCEPT
        Log    elasticsearch_credentials secret not configured; searches may fail if the cluster requires auth.    WARN
        Set Suite Variable    ${elasticsearch_credentials}    ${EMPTY}
    END

    ${ELASTICSEARCH_BASE_URL}=    RW.Core.Import User Variable    ELASTICSEARCH_BASE_URL
    ...    type=string
    ...    description=Base URL for the Elasticsearch HTTP API without path (e.g. https://es.example.com:9200).
    ...    pattern=\w*
    ${ELASTICSEARCH_INDEX_PATTERN}=    RW.Core.Import User Variable    ELASTICSEARCH_INDEX_PATTERN
    ...    type=string
    ...    description=Index name or pattern for the Search API path (e.g. logs-*, filebeat-*).
    ...    pattern=\w*
    ${ELASTICSEARCH_QUERY_BODY}=    RW.Core.Import User Variable    ELASTICSEARCH_QUERY_BODY
    ...    type=string
    ...    description=JSON body for POST _search (query, size, sort, aggregations). Must not include the cluster base URL.
    ...    pattern=\w*
    ${SEARCH_THRESHOLD_MAX_HITS}=    RW.Core.Import User Variable    SEARCH_THRESHOLD_MAX_HITS
    ...    type=string
    ...    description=Optional maximum total hits; exceeding raises an issue when set.
    ...    pattern=\w*
    ...    default=
    ${SEARCH_THRESHOLD_MIN_HITS}=    RW.Core.Import User Variable    SEARCH_THRESHOLD_MIN_HITS
    ...    type=string
    ...    description=Optional minimum total hits; falling below raises an issue when set.
    ...    pattern=\w*
    ...    default=
    ${REQUEST_TIMEOUT_SECONDS}=    RW.Core.Import User Variable    REQUEST_TIMEOUT_SECONDS
    ...    type=string
    ...    description=HTTP client timeout in seconds for search and endpoint probes.
    ...    pattern=^\d+$
    ...    default=60

    Set Suite Variable    ${ELASTICSEARCH_BASE_URL}    ${ELASTICSEARCH_BASE_URL}
    Set Suite Variable    ${ELASTICSEARCH_INDEX_PATTERN}    ${ELASTICSEARCH_INDEX_PATTERN}
    Set Suite Variable    ${ELASTICSEARCH_QUERY_BODY}    ${ELASTICSEARCH_QUERY_BODY}
    Set Suite Variable    ${SEARCH_THRESHOLD_MAX_HITS}    ${SEARCH_THRESHOLD_MAX_HITS}
    Set Suite Variable    ${SEARCH_THRESHOLD_MIN_HITS}    ${SEARCH_THRESHOLD_MIN_HITS}
    Set Suite Variable    ${REQUEST_TIMEOUT_SECONDS}    ${REQUEST_TIMEOUT_SECONDS}

    ${env}=    Create Dictionary
    ...    ELASTICSEARCH_BASE_URL=${ELASTICSEARCH_BASE_URL}
    ...    ELASTICSEARCH_INDEX_PATTERN=${ELASTICSEARCH_INDEX_PATTERN}
    ...    ELASTICSEARCH_QUERY_BODY=${ELASTICSEARCH_QUERY_BODY}
    ...    SEARCH_THRESHOLD_MAX_HITS=${SEARCH_THRESHOLD_MAX_HITS}
    ...    SEARCH_THRESHOLD_MIN_HITS=${SEARCH_THRESHOLD_MIN_HITS}
    ...    REQUEST_TIMEOUT_SECONDS=${REQUEST_TIMEOUT_SECONDS}
    Set Suite Variable    ${env}    ${env}
