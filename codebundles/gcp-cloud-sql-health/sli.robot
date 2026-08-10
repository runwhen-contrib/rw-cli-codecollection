*** Settings ***
Documentation       Measures the health of GCP Cloud SQL instances by scoring instance status, configuration, availability/access, and IAM policy. Produces a value between 0 (completely failing) and 1 (fully passing).
Metadata            Author    rw-codebundle-agent
Metadata            Display Name    GCP Cloud SQL Health
Metadata            Supports    GCP,CloudSQL
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
    ...    description=Optional comma-separated list of Cloud SQL instance names to scope to. Defaults to 'All'.
    ...    pattern=\w*
    ...    default=All
    ${CONFIG_IMPORTANCE_THRESHOLD}=    RW.Core.Import User Variable    CONFIG_IMPORTANCE_THRESHOLD
    ...    type=string
    ...    description=Minimum instance tier vCPU count considered healthy.
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


*** Tasks ***
Score Cloud SQL Instance Status for `${GCP_PROJECT_ID}`
    [Documentation]    Scores instance availability. Returns 1 if all instances are RUNNABLE, 0 if any instance is not.
    [Tags]    gcp    cloudsql    status    data:state-status    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_instance_status.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat instance_status_issues.json | jq length
    ...    env=${env}
    ${status_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${status_score}
    RW.Core.Push Metric    ${status_score}    sub_name=instance_status

Score Cloud SQL Instance Configuration for `${GCP_PROJECT_ID}`
    [Documentation]    Scores instance configuration. Returns 1 if no risky configuration (low tier, backups or PITR disabled) found.
    [Tags]    gcp    cloudsql    config    data:config    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=fetch_instance_config.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat instance_config_issues.json | jq length
    ...    env=${env}
    ${config_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${config_score}
    RW.Core.Push Metric    ${config_score}    sub_name=config

Score Cloud SQL Instance Availability and Access for `${GCP_PROJECT_ID}`
    [Documentation]    Scores availability and access. Returns 1 if no public exposure, missing SSL, exposed authorized networks, or IP issues.
    [Tags]    gcp    cloudsql    security    access    data:config-security    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_instance_access.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat instance_access_issues.json | jq length
    ...    env=${env}
    ${access_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${access_score}
    RW.Core.Push Metric    ${access_score}    sub_name=access

Score Cloud SQL IAM Policies for `${GCP_PROJECT_ID}`
    [Documentation]    Scores IAM policy. Returns 1 if no public or over-broad IAM bindings found.
    [Tags]    gcp    cloudsql    iam    security    data:iam    access:read-only
    ${result}=    RW.CLI.Run Bash File
    ...    bash_file=check_instance_iam.sh
    ...    env=${env}
    ...    secret_file__gcp_credentials=${gcp_credentials}
    ...    timeout_seconds=180
    ${issues_output}=    RW.CLI.Run Cli
    ...    cmd=cat instance_iam_issues.json | jq length
    ...    env=${env}
    ${iam_score}=    Evaluate    1 if int(${issues_output.stdout}) == 0 else 0
    Set Suite Variable    ${iam_score}
    RW.Core.Push Metric    ${iam_score}    sub_name=iam

Generate Aggregate Cloud SQL Health Score for `${GCP_PROJECT_ID}`
    [Documentation]    Averages all sub-scores into a final 0-1 health score for the project's Cloud SQL instances.
    [Tags]    gcp    cloudsql    health    data:metrics    access:read-only
    ${cloud_sql_health_score}=    Evaluate    (${status_score} + ${config_score} + ${access_score} + ${iam_score}) / 4
    ${health_score}=    Convert to Number    ${cloud_sql_health_score}    2
    RW.Core.Add to Report    GCP Cloud SQL Health Score: ${health_score}
    RW.Core.Push Metric    ${health_score}
