*** Settings ***
Documentation       Measures Elasticsearch cluster reachability via GET _cluster/health and produces a score between 0 (unreachable or non-2xx) and 1 (healthy response).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Elasticsearch Generic Log Search
Metadata            Supports    Elasticsearch    logs    HTTP

Suite Setup         Suite Initialization

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

*** Keywords ***
Suite Initialization
    TRY
        ${elasticsearch_credentials}=    RW.Core.Import Secret    elasticsearch_credentials
        ...    type=string
        ...    description=Optional JSON with ELASTICSEARCH_USERNAME, ELASTICSEARCH_PASSWORD, and/or ELASTICSEARCH_API_KEY
        ...    pattern=\w*
        Set Suite Variable    ${elasticsearch_credentials}    ${elasticsearch_credentials}
    EXCEPT
        Set Suite Variable    ${elasticsearch_credentials}    ${EMPTY}
    END

    ${ELASTICSEARCH_BASE_URL}=    RW.Core.Import User Variable    ELASTICSEARCH_BASE_URL
    ...    type=string
    ...    description=Base URL for the Elasticsearch HTTP API without path (e.g. https://es.example.com:9200).
    ...    pattern=\w*
    ${REQUEST_TIMEOUT_SECONDS}=    RW.Core.Import User Variable    REQUEST_TIMEOUT_SECONDS
    ...    type=string
    ...    description=HTTP timeout in seconds for the SLI probe (keep low for fast SLI).
    ...    pattern=^\d+$
    ...    default=15

    Set Suite Variable    ${ELASTICSEARCH_BASE_URL}    ${ELASTICSEARCH_BASE_URL}
    Set Suite Variable    ${REQUEST_TIMEOUT_SECONDS}    ${REQUEST_TIMEOUT_SECONDS}

    ${env}=    Create Dictionary
    ...    ELASTICSEARCH_BASE_URL=${ELASTICSEARCH_BASE_URL}
    ...    REQUEST_TIMEOUT_SECONDS=${REQUEST_TIMEOUT_SECONDS}
    Set Suite Variable    ${env}    ${env}

*** Tasks ***
Probe Elasticsearch Cluster Health for `${ELASTICSEARCH_BASE_URL}`
    [Documentation]    Performs a lightweight GET _cluster/health request and maps a 2xx response to score 1, otherwise 0.
    [Tags]    Elasticsearch    logs    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=sli-elasticsearch-health.sh
    ...    env=${env}
    ...    secret__elasticsearch_credentials=${elasticsearch_credentials}
    ...    include_in_history=false
    ...    timeout_seconds=30
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./sli-elasticsearch-health.sh

    ${score}=    Evaluate    '''${result.stdout}'''.strip()
    ${health_score}=    Evaluate    1 if """${score}""" == "1" else 0
    RW.Core.Push Metric    ${health_score}    sub_name=cluster_reachable
    RW.Core.Add to Report    Elasticsearch SLI health score: ${health_score}
    RW.Core.Push Metric    ${health_score}
