*** Settings ***
Documentation       Measures the health of Cloud Spanner instances by scoring instance state, high-priority CPU utilization, storage utilization, and database state. Produces a value between 0 (completely failing) and 1 (fully passing).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Cloud Spanner Instance Health
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
    ...    description=GCP service account JSON key used to authenticate with GCP APIs. Requires Spanner Viewer and Monitoring Viewer roles.
    ...    pattern=\w*
    ...    example={"type": "service_account","project_id":"myproject-ID"}
    ${GCP_PROJECT_ID}=    RW.Core.Import User Variable    GCP_PROJECT_ID
    ...    type=string
    ...    description=The GCP Project ID to scope the API to.
    ...    pattern=\w*
    ...    example=myproject-id
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
    Set Suite Variable    ${LONG_RUNNING_OPERATION_MINUTES}    ${LONG_RUNNING_OPERATION_MINUTES}
    Set Suite Variable    ${gcp_credentials}    ${gcp_credentials}
    Set Suite Variable
    ...    ${env}
    ...    {"PATH":"$PATH:${OS_PATH}","GCP_PROJECT_ID":"${GCP_PROJECT_ID}","CPU_UTILIZATION_THRESHOLD":"${CPU_UTILIZATION_THRESHOLD}","MULTI_REGION_CPU_UTILIZATION_THRESHOLD":"${MULTI_REGION_CPU_UTILIZATION_THRESHOLD}","STORAGE_UTILIZATION_THRESHOLD":"${STORAGE_UTILIZATION_THRESHOLD}","STORAGE_LIMIT_GB_PER_NODE":"${STORAGE_LIMIT_GB_PER_NODE}","LONG_RUNNING_OPERATION_MINUTES":"${LONG_RUNNING_OPERATION_MINUTES}"}
    RW.CLI.Run CLI
    ...    cmd=gcloud auth activate-service-account --key-file="./${gcp_credentials.key}" || true
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}


*** Tasks ***
Score Cloud Spanner Instance State for `${GCP_PROJECT_ID}`
    [Documentation]    Scores instance state/configuration. Returns 1 if no instances are unready or under-provisioned.
    [Tags]    gcp    spanner    instance    config    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_instance_state.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat instance_state_issues.json | jq length
    ...    env=${env}
    ${state_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${state_score}
    RW.Core.Push Metric    ${state_score}    sub_name=instance_state

Score Cloud Spanner High-Priority CPU Utilization for `${GCP_PROJECT_ID}`
    [Documentation]    Scores high-priority CPU utilization against the config-derived threshold. Returns 1 if no instance exceeds it.
    [Tags]    gcp    spanner    instance    cpu    data:metrics    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_cpu_utilization.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat cpu_utilization_issues.json | jq length
    ...    env=${env}
    ${cpu_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${cpu_score}
    RW.Core.Push Metric    ${cpu_score}    sub_name=cpu_utilization

Score Cloud Spanner Storage Utilization for `${GCP_PROJECT_ID}`
    [Documentation]    Scores storage utilization against the node/PU-derived limit. Returns 1 if no instance is approaching its limit.
    [Tags]    gcp    spanner    instance    storage    data:metrics    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_storage_utilization.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat storage_utilization_issues.json | jq length
    ...    env=${env}
    ${storage_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${storage_score}
    RW.Core.Push Metric    ${storage_score}    sub_name=storage_utilization

Score Cloud Spanner Database State for `${GCP_PROJECT_ID}`
    [Documentation]    Scores database state and long-running DDL operations. Returns 1 if no database issues are found.
    [Tags]    gcp    spanner    database    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_database_state.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat database_state_issues.json | jq length
    ...    env=${env}
    ${database_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${database_score}
    RW.Core.Push Metric    ${database_score}    sub_name=database_state

Generate Aggregate Cloud Spanner Instance Health Score for `${GCP_PROJECT_ID}`
    [Documentation]    Averages all sub-scores into a final 0-1 health score for the project.
    [Tags]    gcp    spanner    instance    health    data:metrics    access:read-only
    ${instance_health_score}=    Evaluate    (${state_score} + ${cpu_score} + ${storage_score} + ${database_score}) / 4
    ${health_score}=    Convert to Number    ${instance_health_score}    2
    RW.Core.Add to Report    Cloud Spanner Instance Health Score: ${health_score}
    RW.Core.Push Metric    ${health_score}
