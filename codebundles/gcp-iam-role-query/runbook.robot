*** Settings ***
Documentation       Queries GCP IAM role bindings on demand for service accounts, resources, services, and the project, returning role and access information driven by runtime variables.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP IAM Role Query
Metadata            Supports    GCP,IAM
Force Tags          GCP    IAM    Role    Query

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Query IAM Roles for Service Account in Project `${GCP_PROJECT_ID}`
    [Documentation]    Returns the full set of IAM role bindings attached to a specific service account, including inherited project and resource bindings.
    [Tags]    gcp    iam    serviceaccount    data:config    access:read-only
    ${sa_result}=    RW.CLI.Run Bash File
    ...    bash_file=query_service_account_roles.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./query_service_account_roles.sh
    ${sa_issues}=    RW.CLI.Run Cli
    ...    cmd=cat service_account_role_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${sa_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for service account role query, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${sa_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    IAM Roles for Service Account Query:\n${sa_result.stdout}

Query IAM Roles Assigned to Resource in Project `${GCP_PROJECT_ID}`
    [Documentation]    Returns the IAM policy and role bindings for a user-supplied GCP resource such as a bucket, service, or project.
    [Tags]    gcp    iam    resource    data:config    access:read-only
    ${res_result}=    RW.CLI.Run Bash File
    ...    bash_file=query_resource_roles.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./query_resource_roles.sh
    ${res_issues}=    RW.CLI.Run Cli
    ...    cmd=cat resource_role_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${res_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for resource role query, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${res_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    IAM Roles Assigned to Resource Query:\n${res_result.stdout}

List IAM Roles for GCP Service in Project `${GCP_PROJECT_ID}`
    [Documentation]    Queries the IAM bindings on a named GCP service type across the project, filtering by the requested resource kind.
    [Tags]    gcp    iam    service    data:config    access:read-only
    ${svc_result}=    RW.CLI.Run Bash File
    ...    bash_file=query_service_roles.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./query_service_roles.sh
    ${svc_issues}=    RW.CLI.Run Cli
    ...    cmd=cat service_role_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${svc_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for service role query, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${svc_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    IAM Roles for GCP Service Query:\n${svc_result.stdout}

Generate IAM Policy Report for Project `${GCP_PROJECT_ID}`
    [Documentation]    Produces a consolidated report of all IAM bindings in the project grouped by principal and role for on-demand auditing.
    [Tags]    gcp    iam    policy    report    data:config    access:read-only
    ${rep_result}=    RW.CLI.Run Bash File
    ...    bash_file=generate_policy_report.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./generate_policy_report.sh
    ${rep_issues}=    RW.CLI.Run Cli
    ...    cmd=cat policy_report_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${rep_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for policy report, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${rep_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    IAM Policy Report:\n${rep_result.stdout}


*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON key used to authenticate with GCP IAM APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID"}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=GCP Project ID that provides the IAM context for queries.
    ...    pattern=\w*
    ...    example=my-gcp-project
    ${SERVICE_ACCOUNT}=    RW.Core.Import User Variable    SERVICE_ACCOUNT
    ...    type=string
    ...    description=Service account email to query role bindings for. Used by the service account role query task.
    ...    pattern=\w*
    ...    default=
    ${RESOURCE_NAME}=    RW.Core.Import User Variable    RESOURCE_NAME
    ...    type=string
    ...    description=Full or short name of the GCP resource to query IAM for. Empty means project-level iteration.
    ...    pattern=\w*
    ...    default=
    ${SERVICE_TYPE}=    RW.Core.Import User Variable    SERVICE_TYPE
    ...    type=string
    ...    description=GCP service type (e.g. storage, bigquery, run) used with RESOURCE_NAME to scope the query.
    ...    pattern=\w*
    ...    default=
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${SERVICE_ACCOUNT}    ${SERVICE_ACCOUNT}
    Set Suite Variable    ${RESOURCE_NAME}    ${RESOURCE_NAME}
    Set Suite Variable    ${SERVICE_TYPE}    ${SERVICE_TYPE}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","SERVICE_ACCOUNT":"${SERVICE_ACCOUNT}","RESOURCE_NAME":"${RESOURCE_NAME}","SERVICE_TYPE":"${SERVICE_TYPE}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
