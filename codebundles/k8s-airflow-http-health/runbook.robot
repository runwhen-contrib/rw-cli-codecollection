*** Settings ***
Documentation       Exposes Apache Airflow webserver (and optionally scheduler/triggerer) health through HTTP probes, REST checks, and kubectl Service/Endpoints correlation.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    Kubernetes Airflow HTTP/API Health
Metadata            Supports    Kubernetes    AKS    EKS    GKE    OpenShift    Airflow    HTTP

Force Tags          Kubernetes    Airflow    HTTP    webserver    health

Library             String
Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform

Suite Setup         Suite Initialization


*** Tasks ***
Resolve Airflow Webserver Base URL for `${AIRFLOW_WEBSERVER_SERVICE_NAME}`
    [Documentation]    Confirms PROXY_BASE_URL or kubectl port-forward can reach the webserver /health endpoint before deeper checks run.
    [Tags]    Kubernetes    Airflow    connectivity    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=resolve-airflow-base-url.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./resolve-airflow-base-url.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat resolve_airflow_base_url_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for resolve base URL task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Airflow webserver should be reachable at PROXY_BASE_URL or via port-forward
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Resolve Airflow base URL results:\n${result.stdout}

Check Airflow Webserver Health Endpoint for `${AIRFLOW_WEBSERVER_SERVICE_NAME}`
    [Documentation]    GETs /health and validates JSON status fields for metadatabase, scheduler, and optional components where reported.
    [Tags]    Kubernetes    Airflow    webserver    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-airflow-webserver-health.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-airflow-webserver-health.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_airflow_webserver_health_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for webserver health task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Airflow /health JSON should report healthy state for active subsystems
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Webserver /health results:\n${result.stdout}

Check Airflow REST API Health or Version for `${AIRFLOW_WEBSERVER_SERVICE_NAME}`
    [Documentation]    Probes read-only API routes such as /api/v1/health or /api/v1/version; optional airflow_api_credentials for authenticated clusters.
    [Tags]    Kubernetes    Airflow    api    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-airflow-api-health.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check-airflow-api-health.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_airflow_api_health_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for API health task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=At least one read-only API route should respond when the webserver API is enabled
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Airflow REST API probe results:\n${result.stdout}

Verify Kubernetes Service and Endpoints for Webserver `${AIRFLOW_WEBSERVER_SERVICE_NAME}`
    [Documentation]    Uses kubectl to confirm the Service exists, Endpoints back it, and ports align with AIRFLOW_HTTP_PORT for triage of networking vs application faults.
    [Tags]    Kubernetes    Airflow    service    access:read-only    data:logs-config

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=verify-airflow-webserver-service.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./verify-airflow-webserver-service.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat verify_airflow_webserver_service_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for Service verification task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Service should exist with Endpoints and an HTTP port matching probes
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Kubernetes Service verification:\n${result.stdout}

Optional Check Scheduler or Triggerer HTTP Health Related to `${AIRFLOW_WEBSERVER_SERVICE_NAME}`
    [Documentation]    When AIRFLOW_SCHEDULER_SERVICE_NAME or AIRFLOW_TRIGGERER_SERVICE_NAME is set, attempts lightweight HTTP port-forward probes; documents skip when charts expose no HTTP listener.
    [Tags]    Kubernetes    Airflow    scheduler    access:read-only    data:metrics

    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check-airflow-scheduler-http-health.sh
    ...    env=${env}
    ...    secret_file__kubeconfig=${kubeconfig}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=false
    ...    cmd_override=./check-airflow-scheduler-http-health.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat check_airflow_scheduler_http_issues.json
    ...    timeout_seconds=30
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for optional scheduler HTTP task, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=Optional scheduler/triggerer Service should exist with endpoints when those tiers are enabled
            ...    actual=${issue['details']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Optional scheduler/triggerer HTTP results:\n${result.stdout}


*** Keywords ***
Suite Initialization
    ${kubeconfig}=    RW.Core.Import Secret
    ...    kubeconfig
    ...    type=string
    ...    description=The kubernetes kubeconfig yaml containing connection configuration used to connect to cluster(s).
    ...    pattern=\w*
    TRY
        ${AIRFLOW_API_CREDENTIALS}=    RW.Core.Import Secret
        ...    airflow_api_credentials
        ...    type=string
        ...    description=Optional JSON with token or username/password for Airflow REST API (for example {\"username\":\"...\",\"password\":\"...\"}).
        ...    pattern=.*
        Set Suite Variable    ${AIRFLOW_API_CREDENTIALS}    ${AIRFLOW_API_CREDENTIALS}
    EXCEPT
        Log    airflow_api_credentials secret not provided; API probes run without authenticated access where allowed.    INFO
        Set Suite Variable    ${AIRFLOW_API_CREDENTIALS}    ${EMPTY}
    END
    ${CONTEXT}=    RW.Core.Import User Variable    CONTEXT
    ...    type=string
    ...    description=Kubernetes context for kubectl and port-forward.
    ...    pattern=\w*
    ${NAMESPACE}=    RW.Core.Import User Variable    NAMESPACE
    ...    type=string
    ...    description=Namespace where Airflow runs.
    ...    pattern=\w*
    ${AIRFLOW_WEBSERVER_SERVICE_NAME}=    RW.Core.Import User Variable    AIRFLOW_WEBSERVER_SERVICE_NAME
    ...    type=string
    ...    description=Kubernetes Service name for the Airflow webserver.
    ...    pattern=.*
    ${PROXY_BASE_URL}=    RW.Core.Import User Variable    PROXY_BASE_URL
    ...    type=string
    ...    description=Optional full base URL for HTTP checks; leave empty to port-forward to the webserver Service.
    ...    pattern=.*
    ...    default=
    ${AIRFLOW_HTTP_PORT}=    RW.Core.Import User Variable    AIRFLOW_HTTP_PORT
    ...    type=string
    ...    description=Service port for the Airflow web UI/API.
    ...    pattern=^\d+$
    ...    default=8080
    ${AIRFLOW_SCHEDULER_SERVICE_NAME}=    RW.Core.Import User Variable    AIRFLOW_SCHEDULER_SERVICE_NAME
    ...    type=string
    ...    description=Optional Service name for scheduler-side HTTP checks when exposed.
    ...    pattern=.*
    ...    default=
    ${AIRFLOW_TRIGGERER_SERVICE_NAME}=    RW.Core.Import User Variable    AIRFLOW_TRIGGERER_SERVICE_NAME
    ...    type=string
    ...    description=Optional Service name for Airflow 2 triggerer HTTP checks when exposed.
    ...    pattern=.*
    ...    default=
    ${KUBERNETES_DISTRIBUTION_BINARY}=    RW.Core.Import User Variable    KUBERNETES_DISTRIBUTION_BINARY
    ...    type=string
    ...    enum=[kubectl,oc]
    ...    default=kubectl
    Set Suite Variable    ${kubeconfig}    ${kubeconfig}
    Set Suite Variable    ${CONTEXT}    ${CONTEXT}
    Set Suite Variable    ${NAMESPACE}    ${NAMESPACE}
    Set Suite Variable    ${AIRFLOW_WEBSERVER_SERVICE_NAME}    ${AIRFLOW_WEBSERVER_SERVICE_NAME}
    Set Suite Variable    ${PROXY_BASE_URL}    ${PROXY_BASE_URL}
    Set Suite Variable    ${AIRFLOW_HTTP_PORT}    ${AIRFLOW_HTTP_PORT}
    Set Suite Variable    ${AIRFLOW_SCHEDULER_SERVICE_NAME}    ${AIRFLOW_SCHEDULER_SERVICE_NAME}
    Set Suite Variable    ${AIRFLOW_TRIGGERER_SERVICE_NAME}    ${AIRFLOW_TRIGGERER_SERVICE_NAME}
    Set Suite Variable    ${KUBERNETES_DISTRIBUTION_BINARY}    ${KUBERNETES_DISTRIBUTION_BINARY}
    ${env}=    Create Dictionary
    ...    CONTEXT=${CONTEXT}
    ...    NAMESPACE=${NAMESPACE}
    ...    AIRFLOW_WEBSERVER_SERVICE_NAME=${AIRFLOW_WEBSERVER_SERVICE_NAME}
    ...    PROXY_BASE_URL=${PROXY_BASE_URL}
    ...    AIRFLOW_HTTP_PORT=${AIRFLOW_HTTP_PORT}
    ...    AIRFLOW_SCHEDULER_SERVICE_NAME=${AIRFLOW_SCHEDULER_SERVICE_NAME}
    ...    AIRFLOW_TRIGGERER_SERVICE_NAME=${AIRFLOW_TRIGGERER_SERVICE_NAME}
    ...    KUBERNETES_DISTRIBUTION_BINARY=${KUBERNETES_DISTRIBUTION_BINARY}
    ...    AIRFLOW_API_CREDENTIALS=${AIRFLOW_API_CREDENTIALS}
    ...    KUBECONFIG=./${kubeconfig.key}
    Set Suite Variable    ${env}    ${env}
