*** Settings ***
Documentation       Monitors GCP Cloud Spanner instance and database health including instance state, high-priority CPU utilization, storage utilization, database state, and request latency/errors.
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Cloud Spanner Instance Health
Metadata            Supports    GCP,Spanner
Force Tags          GCP    Spanner    Instance    Health

Library             BuiltIn
Library             RW.Core
Library             RW.CLI
Library             RW.platform
Library             OperatingSystem
Library             Collections

Suite Setup         Suite Initialization


*** Tasks ***
Check Cloud Spanner Instance State and Configuration for `${GCP_PROJECT_ID}`
    [Documentation]    Verifies each Cloud Spanner instance is in READY state, reports node_count/processing_units and instance config (regional vs multi-region), and flags multi-region instances under-provisioned for their config.
    [Tags]    gcp    spanner    instance    config    data:config    access:read-only
    ${state_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_instance_state.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_instance_state.sh
    ${state_issues}=    RW.CLI.Run Cli
    ...    cmd=cat instance_state_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${state_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for instance state, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${state_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud Spanner Instance State Analysis:\n${state_result.stdout}
    ${instance_config}=    RW.CLI.Run Cli
    ...    cmd=gcloud spanner instances list --project=${GCP_PROJECT_ID} --format=json
    ...    env=${env}
    RW.Core.Add Pre To Report    Cloud Spanner Instance Configurations:\n${instance_config.stdout}

Check Cloud Spanner High-Priority CPU Utilization for `${GCP_PROJECT_ID}`
    [Documentation]    Reads high-priority CPU utilization from Cloud Monitoring and flags instances above the config-derived threshold (65% regional, 45% multi-region by default).
    [Tags]    gcp    spanner    instance    cpu    data:metrics    access:read-only
    ${cpu_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_cpu_utilization.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_cpu_utilization.sh
    ${cpu_issues}=    RW.CLI.Run Cli
    ...    cmd=cat cpu_utilization_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${cpu_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for CPU utilization, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Cloud Spanner CPU Utilization Analysis:\n${cpu_result.stdout}
    RW.Core.Add Pre To Report    Thresholds: regional high-priority CPU ceiling=${CPU_UTILIZATION_THRESHOLD}%, multi-region ceiling=${MULTI_REGION_CPU_UTILIZATION_THRESHOLD}%

Check Cloud Spanner Storage Utilization for `${GCP_PROJECT_ID}`
    [Documentation]    Compares storage used against each instance's storage limit (derived from node/processing-unit count) and flags instances approaching the limit.
    [Tags]    gcp    spanner    instance    storage    data:metrics    access:read-only
    ${storage_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_storage_utilization.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_storage_utilization.sh
    ${storage_issues}=    RW.CLI.Run Cli
    ...    cmd=cat storage_utilization_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${storage_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for storage utilization, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${storage_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud Spanner Storage Utilization Analysis:\n${storage_result.stdout}
    RW.Core.Add Pre To Report    Thresholds: storage ceiling=${STORAGE_UTILIZATION_THRESHOLD}% of the derived limit (${STORAGE_LIMIT_GB_PER_NODE} GB per node / 1000 processing units)

Check Cloud Spanner Database State for `${GCP_PROJECT_ID}`
    [Documentation]    Lists databases per instance, verifies each is READY, and flags long-running schema/DDL operations or databases stuck in CREATING.
    [Tags]    gcp    spanner    database    data:config    access:read-only
    ${db_result}=    RW.CLI.Run Bash File
    ...    bash_file=check_database_state.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./check_database_state.sh
    ${db_issues}=    RW.CLI.Run Cli
    ...    cmd=cat database_state_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${db_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for database state, defaulting to empty list.    WARN
        ${issue_list}=    Create List
    END
    IF    len(@{issue_list}) > 0
        FOR    ${issue}    IN    @{issue_list}
            RW.Core.Add Issue
            ...    severity=${issue['severity']}
            ...    expected=${issue['expected']}
            ...    actual=${issue['actual']}
            ...    title=${issue['title']}
            ...    reproduce_hint=${db_result.cmd}
            ...    details=${issue['details']}
            ...    next_steps=${issue['next_steps']}
        END
    END
    RW.Core.Add Pre To Report    Cloud Spanner Database State Analysis:\n${db_result.stdout}
    ${db_inventory}=    RW.CLI.Run Cli
    ...    cmd=for inst in $(gcloud spanner instances list --project=${GCP_PROJECT_ID} --format="value(name.scope('instances'))"); do echo "== Instance: $inst =="; gcloud spanner databases list --instance=$inst --project=${GCP_PROJECT_ID}; done
    ...    env=${env}
    RW.Core.Add Pre To Report    Cloud Spanner Database Inventory:\n${db_inventory.stdout}

Analyze Cloud Spanner Request Latency and Errors for `${GCP_PROJECT_ID}`
    [Documentation]    Pulls read/write request latency and error/abort rates from Cloud Monitoring and flags instances exceeding latency or error-rate thresholds.
    [Tags]    gcp    spanner    instance    latency    errors    data:metrics    access:read-only
    ${latency_result}=    RW.CLI.Run Bash File
    ...    bash_file=analyze_latency_errors.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    show_in_rwl_cheatsheet=true
    ...    timeout_seconds=180
    ...    cmd_override=./analyze_latency_errors.sh
    ${latency_issues}=    RW.CLI.Run Cli
    ...    cmd=cat latency_errors_issues.json
    ...    env=${env}
    TRY
        ${issue_list}=    Evaluate    json.loads(r'''${latency_issues.stdout}''')    json
    EXCEPT
        Log    Failed to parse JSON for latency/errors, defaulting to empty list.    WARN
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
    RW.Core.Add Pre To Report    Cloud Spanner Latency and Error Analysis:\n${latency_result.stdout}
    RW.Core.Add Pre To Report    Thresholds: latency=${LATENCY_THRESHOLD_MS}ms, error/abort rate=${ERROR_RATE_THRESHOLD_PERCENT}%


*** Keywords ***
Suite Initialization
    ${gcp_credentials}=    RW.Core.Import Secret    gcp_credentials
    ...    type=string
    ...    description=GCP service account JSON key used to authenticate with GCP APIs. Requires Spanner Viewer and Monitoring Viewer roles.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID"}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=GCP Project ID containing the Cloud Spanner instances.
    ...    pattern=\w*
    ...    example=my-gcp-project
    ${CPU_UTILIZATION_THRESHOLD}=    RW.Core.Import User Variable    CPU_UTILIZATION_THRESHOLD
    ...    type=string
    ...    description=High-priority CPU utilization percent (regional instances) above which an issue is raised.
    ...    pattern=\w*
    ...    default=65
    ${MULTI_REGION_CPU_UTILIZATION_THRESHOLD}=    RW.Core.Import User Variable    MULTI_REGION_CPU_UTILIZATION_THRESHOLD
    ...    type=string
    ...    description=High-priority CPU utilization percent (multi-region instances) above which an issue is raised.
    ...    pattern=\w*
    ...    default=45
    ${STORAGE_UTILIZATION_THRESHOLD}=    RW.Core.Import User Variable    STORAGE_UTILIZATION_THRESHOLD
    ...    type=string
    ...    description=Storage % of the node/processing-unit-derived limit above which an issue is raised.
    ...    pattern=\w*
    ...    default=75
    ${STORAGE_LIMIT_GB_PER_NODE}=    RW.Core.Import User Variable    STORAGE_LIMIT_GB_PER_NODE
    ...    type=string
    ...    description=Spanner storage limit in GB per node (or per 1000 processing units), used to derive each instance's storage limit.
    ...    pattern=\w*
    ...    default=4096
    ${LATENCY_THRESHOLD_MS}=    RW.Core.Import User Variable    LATENCY_THRESHOLD_MS
    ...    type=string
    ...    description=Request latency (ms) above which an issue is raised.
    ...    pattern=\w*
    ...    default=100
    ${ERROR_RATE_THRESHOLD_PERCENT}=    RW.Core.Import User Variable    ERROR_RATE_THRESHOLD_PERCENT
    ...    type=string
    ...    description=Request error/abort rate percent above which an issue is raised.
    ...    pattern=\w*
    ...    default=1
    ${LONG_RUNNING_OPERATION_MINUTES}=    RW.Core.Import User Variable    LONG_RUNNING_OPERATION_MINUTES
    ...    type=string
    ...    description=Age in minutes above which an incomplete schema/DDL operation is flagged.
    ...    pattern=\w*
    ...    default=60
    ${OS_PATH}=    Get Environment Variable    PATH
    Set Suite Variable    ${GCP_PROJECT_ID}    ${GCP_PROJECT_ID}
    Set Suite Variable    ${CPU_UTILIZATION_THRESHOLD}    ${CPU_UTILIZATION_THRESHOLD}
    Set Suite Variable    ${MULTI_REGION_CPU_UTILIZATION_THRESHOLD}    ${MULTI_REGION_CPU_UTILIZATION_THRESHOLD}
    Set Suite Variable    ${STORAGE_UTILIZATION_THRESHOLD}    ${STORAGE_UTILIZATION_THRESHOLD}
    Set Suite Variable    ${STORAGE_LIMIT_GB_PER_NODE}    ${STORAGE_LIMIT_GB_PER_NODE}
    Set Suite Variable    ${LATENCY_THRESHOLD_MS}    ${LATENCY_THRESHOLD_MS}
    Set Suite Variable    ${ERROR_RATE_THRESHOLD_PERCENT}    ${ERROR_RATE_THRESHOLD_PERCENT}
    Set Suite Variable    ${LONG_RUNNING_OPERATION_MINUTES}    ${LONG_RUNNING_OPERATION_MINUTES}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","CLOUDSDK_BILLING_QUOTA_PROJECT":"${GCP_PROJECT_ID}","CPU_UTILIZATION_THRESHOLD":"${CPU_UTILIZATION_THRESHOLD}","MULTI_REGION_CPU_UTILIZATION_THRESHOLD":"${MULTI_REGION_CPU_UTILIZATION_THRESHOLD}","STORAGE_UTILIZATION_THRESHOLD":"${STORAGE_UTILIZATION_THRESHOLD}","STORAGE_LIMIT_GB_PER_NODE":"${STORAGE_LIMIT_GB_PER_NODE}","LATENCY_THRESHOLD_MS":"${LATENCY_THRESHOLD_MS}","ERROR_RATE_THRESHOLD_PERCENT":"${ERROR_RATE_THRESHOLD_PERCENT}","LONG_RUNNING_OPERATION_MINUTES":"${LONG_RUNNING_OPERATION_MINUTES}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
