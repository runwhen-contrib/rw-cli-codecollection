*** Settings ***
Documentation       Monitors GCP Cloud SQL instance health covering availability status, configuration, public access/SSL exposure, and IAM policy risks.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Cloud SQL Health
Metadata            Supports    GCP,CloudSQL
Force Tags          GCP    CloudSQL    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Check Cloud SQL Instance Status in Project `${GCP_PROJECT_ID}`
    [Documentation]    Enumerates Cloud SQL instances whose state is not RUNNABLE, including maintenance, failed, or suspended instances, with state messages.
    [Tags]    gcp    cloudsql    status    data:state-status    access:read-only
    ${status_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_instance_status.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_instance_status.sh
    ${status_issues}=    RW.CLI.Run Cli
    ...    cmd=cat instance_status_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${status_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for instance status, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${status_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud SQL Instance Status Analysis:\n${status_result.stdout}

Fetch Cloud SQL Instance Configurations in Project `${GCP_PROJECT_ID}`
    [Documentation]    Dumps each instance's configuration (tier, disk, region, zones, database version, maintenance window, backup settings) and flags risky configuration such as low tier, disabled automated backups, or no point-in-time recovery.
    [Tags]    gcp    cloudsql    config    data:config    access:read-only
    ${config_result}=    RW.CLI.Run Bash File
    ...    bash_file=fetch_instance_config.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./fetch_instance_config.sh
    ${config_issues}=    RW.CLI.Run Cli
    ...    cmd=cat instance_config_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${config_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for instance configuration, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${config_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud SQL Instance Config Analysis:\n${config_result.stdout}

Check Cloud SQL Instance Availability and Access in Project `${GCP_PROJECT_ID}`
    [Documentation]    Flags instances reachable from the public internet or missing SSL enforcement, exposed authorized networks, and instances with IP/environment issues affecting availability.
    [Tags]    gcp    cloudsql    security    access    data:config-security    access:read-only
    ${access_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_instance_access.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_instance_access.sh
    ${access_issues}=    RW.CLI.Run Cli
    ...    cmd=cat instance_access_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${access_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for instance access, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${access_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud SQL Instance Access Analysis:\n${access_result.stdout}

Check Cloud SQL IAM Policies in Project `${GCP_PROJECT_ID}`
    [Documentation]    Fetches IAM policies for each instance and flags risky bindings including allUsers/allAuthenticatedUsers access and over-broad roles.
    [Tags]    gcp    cloudsql    iam    security    data:iam    access:read-only
    ${iam_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_instance_iam.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_instance_iam.sh
    ${iam_issues}=    RW.CLI.Run Cli
    ...    cmd=cat instance_iam_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${iam_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for instance IAM, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${iam_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud SQL IAM Policy Analysis:\n${iam_result.stdout}


*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON key used to authenticate with GCP APIs.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID"}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=GCP Project ID containing the Cloud SQL instances.
    ...    pattern=\w*
    ...    example=my-gcp-project
    ${RESOURCES}=    RW.Core.Import User Variable    RESOURCES
    ...    type=string
    ...    description=Optional comma-separated list of Cloud SQL instance names to scope to. Defaults to 'All' (auto-discover all instances).
    ...    pattern=\w*
    ...    default=All
    ${CONFIG_IMPORTANCE_THRESHOLD}=    RW.Core.Import User Variable    CONFIG_IMPORTANCE_THRESHOLD
    ...    type=string
    ...    description=Minimum instance tier vCPU count considered healthy (instances below this are flagged as undersized).
    ...    pattern=\w*
    ...    default=2
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${RESOURCES}    ${RESOURCES}
    Set Suite Variable    ${CONFIG_IMPORTANCE_THRESHOLD}    ${CONFIG_IMPORTANCE_THRESHOLD}
    Set Suite Variable
    ...    ${env}
    ...    {"CLOUDSDK_BILLING_QUOTA_PROJECT":"${GCP_PROJECT_ID}",PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","RESOURCES":"${RESOURCES}","CONFIG_IMPORTANCE_THRESHOLD":"${CONFIG_IMPORTANCE_THRESHOLD}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
