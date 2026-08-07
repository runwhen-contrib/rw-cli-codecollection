*** Settings ***
Documentation       Monitor the health of Apigee API proxies and their deployments across all environments in an Apigee organization
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Apigee API Proxy Health
Metadata            Supports    GCP,Apigee,API Proxy,API Management
Force Tags          GCP    Apigee    API Proxy    API Management

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization

*** Tasks ***
Discover Apigee API Proxies and Deployments in `${APIGEE_ORG}`
    [Documentation]    Lists all API proxies, environments, and the deployment state (current revision, revision state, status) of every proxy revision across environments, serving as the discovery and input for all downstream check tasks.
    [Tags]    gcloud    apigee    gcp    ${APIGEE_ORG}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=discover_proxies.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./discover_proxies.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat proxy_discovery_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for proxy discovery, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee Proxy Discovery:\n${result.stdout}

Check Apigee Proxy Deployment Health in `${APIGEE_ORG}`
    [Documentation]    For each API proxy, verifies the deployed revision matches the latest available revision and that deployments have a state of 'deployed', flagging proxies that are not deployed at all, are in an error/pending state, or are running a stale (non-latest) revision.
    [Tags]    gcloud    apigee    deployment    gcp    ${APIGEE_ORG}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_deployments.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_deployments.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat deployment_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for deployment health, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee Proxy Deployment Health:\n${result.stdout}

Check Apigee Environment Deployment Coverage in `${APIGEE_ORG}`
    [Documentation]    Identifies environments with no deployed proxies, cross-referencing envgroup/virtual host bindings so an environment that should host traffic but has zero active deployments is flagged.
    [Tags]    gcloud    apigee    environment    gcp    ${APIGEE_ORG}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_environment_coverage.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_environment_coverage.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat coverage_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for environment coverage, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee Environment Deployment Coverage:\n${result.stdout}

Check Apigee Proxy Revision and Approval State in `${APIGEE_ORG}`
    [Documentation]    Detects proxies still in a draft/imported (non-final) state and revisions superseded by a newer revision that has not been promoted to a deployed environment.
    [Tags]    gcloud    apigee    revision    gcp    ${APIGEE_ORG}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_revisions.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_revisions.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat revision_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for revision checks, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee Proxy Revision and Approval State:\n${result.stdout}

Check Apigee Runtime Environment Status in `${APIGEE_ORG}`
    [Documentation]    Verifies Apigee runtime availability per environment using the environment/active Cloud Monitoring metric, flagging environments or instances that are inactive or unavailable.
    [Tags]    gcloud    apigee    monitoring    gcp    ${APIGEE_ORG}    access:read-only    data:metrics
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_runtime_status.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./check_runtime_status.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat runtime_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for runtime status, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee Runtime Environment Status:\n${result.stdout}

Generate Apigee Proxy Health Summary for `${APIGEE_ORG}`
    [Documentation]    Aggregates all proxy, deployment, environment, and runtime findings into a consolidated health summary (proxy totals, deployed vs not-deployed, stale revisions, at-risk environments) with an overall verdict.
    [Tags]    gcloud    apigee    summary    gcp    ${APIGEE_ORG}    access:read-only    data:config
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=generate_proxy_summary.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ...    include_in_history=false
    ...    show_in_rwl_cheatsheet=true
    ...    cmd_override=./generate_proxy_summary.sh
    ${issues}=    RW.CLI.Run Cli
    ...    cmd=cat summary_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for proxy summary, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Apigee Proxy Health Summary:\n${result.stdout}

*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account json used to authenticate with GCP and Apigee APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID", ... super secret stuff ...}
    ${APIGEE_ORG}=    RW.Core.Import User Variable    APIGEE_ORG
    ...    type=string
    ...    description=The Apigee organization name hosting the API proxies to check.
    ...    pattern=\w*
    ...    example=my-apigee-org
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID hosting the Apigee runtime (used for authentication and Cloud Monitoring queries).
    ...    pattern=\w*
    ...    example=myproject-ID
    ${STALE_REVISION_THRESHOLD}=    RW.Core.Import User Variable    STALE_REVISION_THRESHOLD
    ...    type=string
    ...    description=Number of revisions behind latest before a proxy is flagged as stale.
    ...    pattern=^\d+$
    ...    default=1
    ${INCLUDE_DRAFT_PROXIES}=    RW.Core.Import User Variable    INCLUDE_DRAFT_PROXIES
    ...    type=string
    ...    description=Whether to include non-deployed/draft proxies as issues (true) or ignore them (false).
    ...    pattern=^(true|false)$
    ...    default=true
    ${METRIC_LOOKBACK_PERIOD}=    RW.Core.Import User Variable    METRIC_LOOKBACK_PERIOD
    ...    type=string
    ...    description=Cloud Monitoring lookback period for runtime metric queries (seconds, e.g. 3600s).
    ...    pattern=^\d+s$
    ...    default=3600s
    Set Suite Variable    ${APIGEE_ORG}    ${APIGEE_ORG}
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable    ${STALE_REVISION_THRESHOLD}    ${STALE_REVISION_THRESHOLD}
    Set Suite Variable    ${INCLUDE_DRAFT_PROXIES}    ${INCLUDE_DRAFT_PROXIES}
    Set Suite Variable    ${METRIC_LOOKBACK_PERIOD}    ${METRIC_LOOKBACK_PERIOD}
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_CORE_PROJECT":"${GCP_PROJECT_ID}","PATH":"$PATH:${OS_PATH}","APIGEE_ORG":"${APIGEE_ORG}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","STALE_REVISION_THRESHOLD":"${STALE_REVISION_THRESHOLD}","INCLUDE_DRAFT_PROXIES":"${INCLUDE_DRAFT_PROXIES}","METRIC_LOOKBACK_PERIOD":"${METRIC_LOOKBACK_PERIOD}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
